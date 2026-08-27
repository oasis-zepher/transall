import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ReleaseWorkflowTests(unittest.TestCase):
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
