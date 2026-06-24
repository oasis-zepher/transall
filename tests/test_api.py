import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image


class ApiContractTests(unittest.TestCase):
    def test_provider_endpoint_masks_secrets(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"OPENAI_API_KEY": "sk-secret"}, clear=False):
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.get("/api/config/providers")

        self.assertEqual(response.status_code, 200)
        self.assertNotIn("sk-secret", response.text)
        self.assertTrue(response.json()["providers"][0]["configured"])

    def test_diagnostics_endpoint_masks_secrets_and_reports_dependencies(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp, patch.dict(
            os.environ,
            {"OPENAI_API_KEY": "sk-secret", "DEEPSEEK_API_KEY": ""},
            clear=False,
        ), patch("app.diagnostics.command_available") as command_available, patch(
            "app.diagnostics.python_module_available"
        ) as python_module_available:
            command_available.side_effect = lambda command: command in {"soffice", "tesseract", "babeldoc"}
            python_module_available.side_effect = lambda module: module in {"markitdown", "playwright"}

            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.get("/api/diagnostics")

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        by_name = {item["name"]: item for item in payload["dependencies"]}

        self.assertTrue(by_name["libreoffice"]["available"])
        self.assertTrue(by_name["tesseract"]["available"])
        self.assertTrue(by_name["babeldoc"]["available"])
        self.assertFalse(by_name["pdf2zh"]["available"])
        self.assertTrue(by_name["openai"]["available"])
        self.assertFalse(by_name["deepseek"]["available"])
        self.assertIn("Convert Office files to PDF", by_name["libreoffice"]["required_for"])
        self.assertIn("brew install libreoffice", by_name["libreoffice"]["install_hint"])
        self.assertNotIn("sk-secret", response.text)

    def test_job_endpoint_accepts_image_to_pdf_task(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp:
            image_path = Path(tmp) / "sample.png"
            Image.new("RGB", (80, 60), "white").save(image_path)

            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp) / "data", run_background_inline=True))
            with image_path.open("rb") as handle:
                response = client.post(
                    "/api/jobs",
                    data={"kind": "convert", "options": "{}"},
                    files={"files": ("sample.png", handle, "image/png")},
                )

            self.assertEqual(response.status_code, 200)
            job = response.json()
            self.assertEqual(job["kind"], "convert")
            self.assertEqual(job["status"], "done")
            self.assertTrue(job["output"].endswith(".pdf"))

    def test_job_endpoint_accepts_image_ocr_task(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp:
            image_path = Path(tmp) / "scan.png"
            Image.new("RGB", (80, 60), "white").save(image_path)

            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp) / "data", run_background_inline=True))
            with patch("app.main.ocr_document") as ocr_document:
                def fake_ocr(source, output_dir, language="eng", output_format="text"):
                    output = output_dir / f"{source.stem}-ocr.txt"
                    output.write_text("recognized text", encoding="utf-8")
                    return output

                ocr_document.side_effect = fake_ocr
                with image_path.open("rb") as handle:
                    response = client.post(
                        "/api/jobs",
                        data={"kind": "ocr", "options": '{"output_format":"text","language":"eng"}'},
                        files={"files": ("scan.png", handle, "image/png")},
                    )

            self.assertEqual(response.status_code, 200)
            job = response.json()
            self.assertEqual(job["kind"], "ocr")
            self.assertEqual(job["status"], "done")
            self.assertTrue(job["output"].endswith("-ocr.txt"))


if __name__ == "__main__":
    unittest.main()
