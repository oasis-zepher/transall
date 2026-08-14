import os
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image


class ApiContractTests(unittest.TestCase):
    def test_cross_origin_state_change_is_rejected(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp:
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.post("/api/cleanup", headers={"Origin": "https://evil.example"})

        self.assertEqual(response.status_code, 403)

    def test_local_origin_state_change_is_allowed(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp:
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.post("/api/cleanup", headers={"Origin": "http://127.0.0.1:8765"})

        self.assertEqual(response.status_code, 200)

    def test_cross_origin_reads_are_not_blocked(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp:
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.get("/api/diagnostics", headers={"Origin": "https://evil.example"})

        self.assertEqual(response.status_code, 200)

    def test_running_job_cannot_be_deleted(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp, patch("app.main.run_job"):
            from app.main import create_app

            root = Path(tmp)
            client = TestClient(create_app(data_dir=root, run_background_inline=True))
            created = client.post(
                "/api/jobs",
                data={"kind": "convert", "options": "{}"},
                files={"files": ("notes.txt", io.BytesIO(b"hello"), "text/plain")},
            ).json()

            from app.jobs import JobStore

            store = JobStore(root, ttl_hours=24)
            store.set_status(store.get(created["id"]), "running")
            response = client.delete(f"/api/jobs/{created['id']}")

        self.assertEqual(response.status_code, 409)

    def test_preview_pages_follow_natural_page_order(self):
        import fitz

        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp:
            from app.main import create_app
            from app.jobs import JobStore

            root = Path(tmp)
            client = TestClient(create_app(data_dir=root))
            store = JobStore(root, ttl_hours=24)
            job = store.create("convert", ["sample.pdf"])
            upload_dir = job.path / "uploads"
            upload_dir.mkdir()
            doc_path = upload_dir / "sample.pdf"
            doc = fitz.open()
            doc.new_page()
            doc.save(doc_path)
            doc.close()
            preview_dir = job.path / "preview"
            preview_dir.mkdir()
            for number in range(1, 13):
                (preview_dir / f"page-{number}.png").write_bytes(b"png")

            response = client.get(f"/api/jobs/{job.id}/preview/pages")

        pages = response.json()["pages"]
        self.assertEqual([Path(page["url"]).name for page in pages], [f"page-{number}.png" for number in range(1, 13)])

    def test_job_response_hides_absolute_storage_paths(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp, patch("app.main.run_job"):
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp), run_background_inline=True))
            response = client.post(
                "/api/jobs",
                data={"kind": "convert", "options": "{}"},
                files={"files": ("notes.txt", io.BytesIO(b"hello"), "text/plain")},
            )

        self.assertEqual(response.status_code, 200)
        self.assertNotIn("path", response.json())
        self.assertNotIn(tmp, response.text)

    def test_duplicate_upload_names_are_preserved_with_unique_names(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp, patch("app.main.run_job"):
            from app.main import create_app

            root = Path(tmp)
            client = TestClient(create_app(data_dir=root, run_background_inline=True))
            response = client.post(
                "/api/jobs",
                data={"kind": "convert", "options": "{}"},
                files=[
                    ("files", ("same.txt", io.BytesIO(b"first"), "text/plain")),
                    ("files", ("same.txt", io.BytesIO(b"second"), "text/plain")),
                ],
            )
            job = response.json()
            uploads = root / job["id"] / "uploads"

            self.assertEqual(job["inputs"], ["same.txt", "same-2.txt"])
            self.assertEqual((uploads / "same.txt").read_bytes(), b"first")
            self.assertEqual((uploads / "same-2.txt").read_bytes(), b"second")

    def test_oversized_upload_removes_partial_job_directory(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp, patch("app.main.MAX_UPLOAD_BYTES", 4):
            from app.main import create_app

            root = Path(tmp)
            client = TestClient(create_app(data_dir=root, run_background_inline=True))
            response = client.post(
                "/api/jobs",
                data={"kind": "convert", "options": "{}"},
                files={"files": ("large.txt", io.BytesIO(b"12345"), "text/plain")},
            )

            self.assertEqual(response.status_code, 413)
            self.assertEqual(list(root.iterdir()), [])

    def test_queued_job_can_be_cancelled(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp, patch("app.main.run_job"):
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp), run_background_inline=True))
            created = client.post(
                "/api/jobs",
                data={"kind": "convert", "options": "{}"},
                files={"files": ("notes.txt", io.BytesIO(b"hello"), "text/plain")},
            ).json()
            response = client.post(f"/api/jobs/{created['id']}/cancel")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "cancelled")
        self.assertTrue(response.json()["cancel_requested"])

    def test_favicon_request_does_not_log_browser_404(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp:
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.get("/favicon.ico")

        self.assertEqual(response.status_code, 204)

    def test_capabilities_endpoint_lists_core_routes(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp:
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.get("/api/capabilities")

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        routes = {(route["source"], route["target"]): route for route in payload["routes"]}

        self.assertIn("formats", payload)
        self.assertEqual(len(payload["routes"]), 18)
        for route in payload["routes"]:
            self.assertIn("engine", route)
            self.assertIn("fallbackEngines", route)
            self.assertIn("dependencyProfile", route)
            self.assertIn("licenseNote", route)
        self.assertEqual(routes[("pdf", "translated_pdf")]["kind"], "pdf_translate")
        self.assertEqual(routes[("pdf", "translated_pdf")]["engine"], "babeldoc")
        self.assertEqual(routes[("pdf", "translated_pdf")]["fallbackEngines"], ["builtin_pdf_translate"])
        self.assertEqual(routes[("pdf", "ocr")]["kind"], "ocr")
        self.assertEqual(routes[("pdf", "ocr")]["engine"], "ocrmypdf_ocr")
        self.assertEqual(routes[("pdf", "ocr")]["fallbackEngines"], ["tesseract_ocr"])
        self.assertEqual(routes[("image", "ocr")]["kind"], "ocr")
        self.assertEqual(routes[("pdf", "pdf")]["kind"], "pdf_edit")
        self.assertEqual(routes[("word", "pdf")]["kind"], "convert")
        self.assertEqual(routes[("data", "md")]["kind"], "extract_markdown")
        self.assertEqual(routes[("image", "pdf")]["engine"], "transall_image_pdf")
        self.assertEqual(routes[("data", "pdf")]["engine"], "transall_browser_pdf")
        self.assertEqual(routes[("word", "pdf")]["engine"], "libreoffice_pdf")
        self.assertEqual(routes[("pdf", "pdf")]["engine"], "pymupdf_pdf_edit")
        self.assertIn("license_sensitive", {item["risk"] for item in routes[("pdf", "pdf")]["dependencyProfile"]})

    def test_preflight_blocks_missing_libreoffice_for_office_pdf(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp, patch("app.diagnostics.command_available", return_value=False), patch(
            "app.diagnostics.python_module_available", return_value=True
        ):
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.post(
                "/api/preflight",
                json={
                    "source_format": "word",
                    "target_format": "pdf",
                    "kind": "convert",
                    "files": [{"name": "report.docx", "size": 1024}],
                    "options": {},
                },
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["blocking_issues"][0]["code"], "missing_dependency")
        self.assertEqual(payload["blocking_issues"][0]["dependency"], "libreoffice")

    def test_preflight_blocks_missing_markitdown_for_non_ocr_markdown_route(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp, patch("app.diagnostics.command_available", return_value=True), patch(
            "app.diagnostics.python_module_available", return_value=False
        ):
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.post(
                "/api/preflight",
                json={
                    "source_format": "word",
                    "target_format": "md",
                    "kind": "extract_markdown",
                    "files": [{"name": "report.docx", "size": 1024}],
                    "options": {},
                },
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["blocking_issues"][0]["code"], "missing_dependency")
        self.assertEqual(payload["blocking_issues"][0]["dependency"], "markitdown")

    def test_preflight_blocks_missing_tesseract_for_ocr(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp, patch("app.diagnostics.command_available", return_value=False), patch(
            "app.diagnostics.python_module_available", return_value=True
        ):
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.post(
                "/api/preflight",
                json={
                    "source_format": "image",
                    "target_format": "ocr",
                    "kind": "ocr",
                    "files": [{"name": "scan.png", "size": 1024}],
                    "options": {"language": "chi_sim+eng"},
                },
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["blocking_issues"][0]["code"], "missing_dependency")
        self.assertEqual(payload["blocking_issues"][0]["dependency"], "tesseract")

    def test_preflight_blocks_pdf_translation_without_provider(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp, patch.dict(
            os.environ,
            {"DEEPSEEK_API_KEY": "", "OPENAI_API_KEY": ""},
            clear=False,
        ), patch("app.diagnostics.command_available", return_value=False), patch(
            "app.diagnostics.python_module_available", return_value=True
        ):
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.post(
                "/api/preflight",
                json={
                    "source_format": "pdf",
                    "target_format": "translated_pdf",
                    "kind": "pdf_translate",
                    "files": [{"name": "paper.pdf", "size": 1024}],
                    "options": {"provider": "deepseek"},
                },
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["blocking_issues"][0]["code"], "missing_provider")
        self.assertEqual(payload["blocking_issues"][0]["dependency"], "deepseek")

    def test_preflight_warns_for_missing_optional_translation_engines(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp, patch.dict(
            os.environ,
            {"DEEPSEEK_API_KEY": "sk-test", "OPENAI_API_KEY": ""},
            clear=False,
        ), patch("app.diagnostics.command_available", return_value=False), patch(
            "app.diagnostics.python_module_available", return_value=True
        ):
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.post(
                "/api/preflight",
                json={
                    "source_format": "pdf",
                    "target_format": "translated_pdf",
                    "kind": "pdf_translate",
                    "files": [{"name": "paper.pdf", "size": 1024}],
                    "options": {"provider": "deepseek"},
                },
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["blocking_issues"], [])
        warning_codes = {warning["code"] for warning in payload["warnings"]}
        self.assertIn("optional_dependency_missing", warning_codes)

    def test_preflight_blocks_total_uploads_over_limit(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp:
            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.post(
                "/api/preflight",
                json={
                    "source_format": "image",
                    "target_format": "pdf",
                    "kind": "convert",
                    "files": [{"name": "large.png", "size": 201 * 1024 * 1024}],
                    "options": {},
                },
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["blocking_issues"][0]["code"], "upload_too_large")

    def test_failed_job_returns_structured_error_fields(self):
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "notes.txt"
            source.write_text("not a pdf", encoding="utf-8")

            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp) / "data", run_background_inline=True))
            with source.open("rb") as handle:
                response = client.post(
                    "/api/jobs",
                    data={"kind": "pdf_edit", "options": "{}"},
                    files={"files": ("notes.txt", handle, "text/plain")},
                )

        self.assertEqual(response.status_code, 200)
        job = response.json()
        self.assertEqual(job["status"], "failed")
        self.assertEqual(job["stage"], "failed")
        self.assertEqual(job["error_code"], "pdf_input_required")
        self.assertTrue(job["error_hint"])
        self.assertFalse(job["retryable"])

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
            command_available.side_effect = lambda command: command in {"soffice", "tesseract", "babeldoc", "ocrmypdf"}
            python_module_available.side_effect = lambda module: module in {"markitdown", "playwright"}

            from app.main import create_app

            client = TestClient(create_app(data_dir=Path(tmp)))
            response = client.get("/api/diagnostics")

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        by_name = {item["name"]: item for item in payload["dependencies"]}

        self.assertTrue(by_name["libreoffice"]["available"])
        self.assertTrue(by_name["tesseract"]["available"])
        self.assertTrue(by_name["ocrmypdf"]["available"])
        self.assertTrue(by_name["babeldoc"]["available"])
        self.assertTrue(by_name["openai"]["available"])
        self.assertFalse(by_name["deepseek"]["available"])
        self.assertIn("Convert Office files to PDF", by_name["libreoffice"]["required_for"])
        self.assertIn("brew install libreoffice", by_name["libreoffice"]["install_hint"])
        self.assertEqual(by_name["libreoffice"]["category"], "external_tool")
        self.assertEqual(by_name["libreoffice"]["risk"], "heavy")
        self.assertEqual(by_name["markitdown"]["category"], "optional")
        self.assertEqual(by_name["pymupdf"]["risk"], "license_sensitive")
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
                def fake_ocr(source, output_dir, language="eng", output_format="text", cancel_check=None):
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
