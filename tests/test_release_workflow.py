import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ReleaseWorkflowTests(unittest.TestCase):
    def test_native_job_verifies_xcodegen_project_before_compilation(self):
        workflow = (ROOT / ".github/workflows/tests.yml").read_text(encoding="utf-8")

        install = workflow.index(
            'run: scripts/install_pinned_xcodegen.sh "$RUNNER_TEMP/xcodegen" '
            '>> "$GITHUB_PATH"'
        )
        verify = workflow.index("run: scripts/verify_xcodegen_project.sh")
        compile_step = workflow.index("run: xcrun swift-format lint")

        self.assertLess(install, verify)
        self.assertLess(verify, compile_step)

    def test_xcodegen_installer_uses_a_pinned_verified_release(self):
        installer = (
            ROOT / "native/TransallMac/scripts/install_pinned_xcodegen.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("readonly xcodegen_version=2.46.0", installer)
        self.assertIn(
            "readonly xcodegen_sha256="
            "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
            installer,
        )
        self.assertIn("https://github.com/yonaskolb/XcodeGen/releases/download/", installer)
        self.assertIn("shasum -a 256", installer)
        self.assertIn('!= "Version: ${xcodegen_version}"', installer)

    def test_xcodegen_verifier_uses_an_isolated_project_and_checks_every_output(self):
        verifier = (
            ROOT / "native/TransallMac/scripts/verify_xcodegen_project.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("readonly required_version=2.46.0", verifier)
        self.assertIn('mktemp -d "${TMPDIR:-/tmp}/transall-xcodegen.', verifier)
        self.assertIn('cp -R "$project_root/Sources"', verifier)
        self.assertIn('cp -R "$project_root/Resources"', verifier)
        self.assertIn('cp -R "$project_root/Tests"', verifier)
        self.assertIn('"$xcodegen_binary" generate', verifier)
        self.assertIn("git ls-files -- Transall.xcodeproj", verifier)
        self.assertIn("find Transall.xcodeproj -type f -print", verifier)
        self.assertIn(
            'diff -u "$project_root/$relative_path" '
            '"$temporary_root/$relative_path"',
            verifier,
        )
        self.assertIn(
            'diff -u "$project_root/Support/Info.plist" '
            '"$temporary_root/Support/Info.plist"',
            verifier,
        )

    def test_native_job_invokes_release_metadata_validator(self):
        workflow = (ROOT / ".github/workflows/tests.yml").read_text(encoding="utf-8")

        self.assertIn("run: scripts/validate_release_metadata.sh", workflow)

    def test_release_metadata_validator_lints_every_release_file_in_one_command(self):
        validator = (
            ROOT / "native/TransallMac/scripts/validate_release_metadata.sh"
        ).read_text(encoding="utf-8")
        lines = validator.splitlines()
        start = lines.index("plutil -lint \\")
        command_lines = [lines[start]]
        for line in lines[start + 1 :]:
            command_lines.append(line)
            if not line.rstrip().endswith("\\"):
                break

        lint_command = " ".join(
            line.strip().removesuffix("\\").strip() for line in command_lines
        )
        self.assertEqual(
            lint_command,
            "plutil -lint Support/Info.plist Support/Transall.entitlements "
            "Support/Transall.Debug.entitlements Resources/PrivacyInfo.xcprivacy",
        )
        self.assertIn("CFBundleDevelopmentRegion", validator)
        self.assertIn("CFBundleLocalizations.0", validator)
        self.assertEqual(validator.count('= "zh-Hans"'), 2)
