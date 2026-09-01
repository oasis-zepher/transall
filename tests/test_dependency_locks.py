import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIN_PATTERN = re.compile(
    r"^([A-Za-z0-9_.-]+)(?:\[[^]]+\])?==([^\s;\\]+)(?:\s*;.*)?(?:\s*\\)?$"
)
LOCK_PATTERN = re.compile(r"^([A-Za-z0-9_.-]+)==([^\s;\\]+)(?:\s*;.*)?\s*\\$")


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def read_direct_pins(path: Path) -> dict[str, str]:
    pins: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = PIN_PATTERN.fullmatch(line)
        if match is None:
            raise AssertionError(f"{path.name} contains a non-exact requirement: {line}")
        pins[normalize(match.group(1))] = match.group(2)
    return pins


def read_lock(path: Path) -> dict[str, tuple[str, int]]:
    packages: dict[str, tuple[str, int]] = {}
    current_name: str | None = None
    current_version: str | None = None
    current_hashes = 0

    def finish() -> None:
        nonlocal current_name, current_version, current_hashes
        if current_name is not None and current_version is not None:
            packages[current_name] = (current_version, current_hashes)
        current_name = None
        current_version = None
        current_hashes = 0

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        match = LOCK_PATTERN.match(raw_line)
        if match is not None:
            finish()
            current_name = normalize(match.group(1))
            current_version = match.group(2)
        elif current_name is not None and "--hash=sha256:" in raw_line:
            current_hashes += 1
    finish()
    return packages


class DependencyLockTests(unittest.TestCase):
    def test_source_requirements_are_exactly_pinned(self):
        for filename in ("requirements.txt", "requirements-optional.txt", "requirements-ci.txt"):
            with self.subTest(filename=filename):
                self.assertTrue(read_direct_pins(ROOT / filename))

    def test_runtime_lock_covers_direct_and_transitive_packages_with_hashes(self):
        direct = {
            **read_direct_pins(ROOT / "requirements.txt"),
            **read_direct_pins(ROOT / "requirements-optional.txt"),
        }
        locked = read_lock(ROOT / "requirements.lock")

        self.assertGreater(len(locked), len(direct))
        for name, version in direct.items():
            self.assertIn(name, locked)
            self.assertEqual(locked[name][0], version)
        self.assertTrue(all(hash_count > 0 for _, hash_count in locked.values()))

    def test_ci_lock_is_a_hashed_superset_of_runtime_lock(self):
        runtime = read_lock(ROOT / "requirements.lock")
        ci = read_lock(ROOT / "requirements-ci.lock")
        tools = read_direct_pins(ROOT / "requirements-ci.txt")

        self.assertGreater(len(ci), len(runtime))
        for name, (version, _) in runtime.items():
            self.assertIn(name, ci)
            self.assertEqual(ci[name][0], version)
        for name, version in tools.items():
            self.assertIn(name, ci)
            self.assertEqual(ci[name][0], version)
        self.assertTrue(all(hash_count > 0 for _, hash_count in ci.values()))

    def test_workflow_installs_only_the_hashed_ci_lock(self):
        workflow = (ROOT / ".github/workflows/tests.yml").read_text(encoding="utf-8")

        self.assertIn(
            "python -m pip install --require-hashes -r requirements-ci.lock",
            workflow,
        )
        self.assertNotIn(
            "python -m pip install -r requirements.lock coverage ruff bandit pip-audit",
            workflow,
        )
        self.assertIn(
            "pip-audit --disable-pip --vulnerability-service osv",
            workflow,
        )

    def test_lock_compiler_is_versioned_and_hashes_both_outputs(self):
        compiler = (ROOT / "scripts/compile_python_locks.sh").read_text(encoding="utf-8")

        self.assertIn('expected_uv_version="0.10.12"', compiler)
        self.assertIn("--python-version 3.13", compiler)
        self.assertIn("--universal", compiler)
        self.assertIn("--generate-hashes", compiler)
        for filename in (
            "requirements.txt",
            "requirements-optional.txt",
            "requirements-ci.txt",
            "requirements.lock",
            "requirements-ci.lock",
        ):
            with self.subTest(filename=filename):
                self.assertIn(filename, compiler)


if __name__ == "__main__":
    unittest.main()
