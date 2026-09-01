import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ReleaseWorkflowTests(unittest.TestCase):
    def test_third_party_actions_are_pinned_to_full_release_commits(self):
        workflow = (ROOT / ".github/workflows/tests.yml").read_text(encoding="utf-8")
        action_refs = re.findall(r"^\s*- uses:\s+([^\s#]+)", workflow, re.MULTILINE)

        self.assertEqual(len(action_refs), 5)
        for action_ref in action_refs:
            with self.subTest(action_ref=action_ref):
                self.assertRegex(action_ref, r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$")

        self.assertEqual(
            action_refs.count(
                "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
            ),
            3,
        )
        self.assertIn(
            "actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97",
            action_refs,
        )
        self.assertIn(
            "actions/setup-node@820762786026740c76f36085b0efc47a31fe5020",
            action_refs,
        )

    def test_dependabot_tracks_pinned_github_actions(self):
        config = (ROOT / ".github/dependabot.yml").read_text(encoding="utf-8")

        self.assertIn("package-ecosystem: github-actions", config)
        self.assertIn("directory: /", config)
        self.assertIn("interval: weekly", config)

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
        self.assertIn(
            'mktemp "${TMPDIR:-/tmp}/transall-xcodegen.XXXXXX"', installer
        )
        self.assertNotIn("transall-xcodegen.XXXXXX.zip", installer)

    @unittest.skipUnless(sys.platform == "darwin", "macOS mktemp behavior")
    def test_xcodegen_archive_template_creates_distinct_private_paths_on_macos(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            legacy_literal = root / "transall-xcodegen.XXXXXX.zip"
            legacy_literal.touch(mode=0o600)
            template = str(root / "transall-xcodegen.XXXXXX")

            paths = [
                Path(
                    subprocess.run(
                        ["mktemp", template],
                        check=True,
                        capture_output=True,
                        text=True,
                    ).stdout.strip()
                )
                for _ in range(2)
            ]

            self.assertNotEqual(paths[0], paths[1])
            self.assertTrue(all(path.exists() for path in paths))
            self.assertTrue(all("XXXXXX" not in path.name for path in paths))
            self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600 for path in paths))
            self.assertTrue(legacy_literal.exists())

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
        self.assertIn("run: scripts/test_release_metadata_validator.sh", workflow)

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
        self.assertIn(
            "expect_raw_value Support/Info.plist CFBundleDevelopmentRegion zh-Hans",
            validator,
        )
        self.assertIn(
            "expect_raw_value Support/Info.plist CFBundleLocalizations.0 zh-Hans",
            validator,
        )

    def test_release_metadata_validator_checks_reviewed_semantics(self):
        validator = (
            ROOT / "native/TransallMac/scripts/validate_release_metadata.sh"
        ).read_text(encoding="utf-8")
        regression = (
            ROOT / "native/TransallMac/scripts/test_release_metadata_validator.sh"
        ).read_text(encoding="utf-8")

        for expected_value in (
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.network.client",
            "ITSAppUsesNonExemptEncryption",
            "public.app-category.productivity",
            "NSPrivacyTrackingDomains",
            "NSPrivacyCollectedDataTypeOtherUserContent",
            "NSPrivacyCollectedDataTypePurposeAppFunctionality",
            "NSPrivacyAccessedAPICategoryUserDefaults",
            "CA92.1",
            "NSPrivacyAccessedAPICategoryFileTimestamp",
            "C617.1",
        ):
            self.assertIn(expected_value, validator)

        self.assertIn("unmodified release metadata", regression)
        self.assertIn("missing $entitlement_key", regression)
        self.assertIn("disables $entitlement_key", regression)
        self.assertIn("enables tracking", regression)
        self.assertIn("adds a tracking domain", regression)
        self.assertIn("changes collected-data purpose", regression)
        self.assertIn("changes UserDefaults reason", regression)
        self.assertIn("changes file-timestamp reason", regression)

    def test_archive_requires_configured_public_transall_privacy_url(self):
        project = (ROOT / "native/TransallMac/project.yml").read_text(encoding="utf-8")
        metadata_validator = (
            ROOT / "native/TransallMac/scripts/validate_release_metadata.sh"
        ).read_text(encoding="utf-8")
        archive_validator = (
            ROOT / "native/TransallMac/scripts/validate_archive_privacy_policy.sh"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "TransallPrivacyPolicyURL: $(TRANSALL_PRIVACY_POLICY_URL)", project
        )
        self.assertIn('if [ "${ACTION:-}" = "install" ]', project)
        self.assertIn("validate_archive_privacy_policy.sh", project)
        self.assertIn("TransallPrivacyPolicyURL", metadata_validator)
        self.assertIn("plutil -extract TransallPrivacyPolicyURL raw", archive_validator)
        self.assertIn('if [[ "$policy_url" != https://* ]]', archive_validator)
        self.assertIn(
            "*.example | *.invalid | *.local | *.localhost | *.test",
            archive_validator,
        )
