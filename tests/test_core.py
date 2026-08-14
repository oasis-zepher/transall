import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import fitz
from PIL import Image


def make_pdf(path: Path) -> None:
    doc = fitz.open()
    for text in ("alpha marker", "beta marker", "gamma marker"):
        page = doc.new_page()
        page.insert_text((72, 96), text, fontsize=14)
    doc.save(path)
    doc.close()


class CoreBehaviorTests(unittest.TestCase):
    def test_page_spec_supports_ranges_and_open_ranges(self):
        from app.pdf_ops import parse_page_spec

        self.assertEqual(parse_page_spec("1,3-4,-2,9-", 10), [1, 2, 3, 4, 9, 10])
        self.assertEqual(parse_page_spec("", 4), [1, 2, 3, 4])

    def test_provider_config_masks_keys(self):
        from app.translation import load_provider_configs

        with patch.dict(
            os.environ,
            {
                "OPENAI_API_KEY": "sk-openai-secret",
                "OPENAI_MODEL": "gpt-4o-mini",
                "DEEPSEEK_API_KEY": "sk-deepseek-secret",
                "DEEPSEEK_MODEL": "deepseek-chat",
            },
            clear=False,
        ):
            providers = load_provider_configs()

        by_name = {provider["name"]: provider for provider in providers}
        self.assertTrue(by_name["openai"]["configured"])
        self.assertTrue(by_name["deepseek"]["configured"])
        self.assertNotIn("sk-openai-secret", str(providers))
        self.assertEqual(by_name["openai"]["model"], "gpt-4o-mini")

    def test_job_store_creates_private_task_directory(self):
        from app.jobs import JobStore

        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp), ttl_hours=24)
            job = store.create("convert", ["report.docx"])

            self.assertEqual(job.kind, "convert")
            self.assertEqual(job.status, "queued")
            self.assertTrue(job.path.exists())
            self.assertTrue(job.path.is_dir())
            self.assertEqual(job.inputs, ["report.docx"])

    def test_job_store_recovers_interrupted_jobs(self):
        from app.jobs import JobStore

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root, ttl_hours=24)
            job = store.create("convert", ["report.docx"])
            store.set_status(job, "running", stage="converting", progress=40)

            recovered = JobStore(root, ttl_hours=24).recover_interrupted()
            current = store.get(job.id)

        self.assertEqual(recovered, 1)
        self.assertEqual(current.status, "failed")
        self.assertEqual(current.error_code, "interrupted")
        self.assertTrue(current.retryable)

    def test_job_store_public_payload_hides_filesystem_paths(self):
        from app.jobs import JobStore

        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp), ttl_hours=24)
            job = store.create("convert", ["report.docx"])
            output = job.path / "outputs" / "report.pdf"
            output.parent.mkdir()
            output.write_bytes(b"%PDF-1.7\n")
            store.set_output(job, output)
            payload = job.public()

        self.assertNotIn("path", payload)
        self.assertEqual(payload["output"], "report.pdf")

    def test_pdf_edit_can_delete_rotate_and_replace_text(self):
        from app.pdf_ops import PdfEditOptions, apply_pdf_edits

        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "source.pdf"
            out = Path(tmp) / "edited.pdf"
            make_pdf(src)

            apply_pdf_edits(
                src,
                out,
                PdfEditOptions(
                    delete_pages=[2],
                    rotate_pages={1: 90},
                    replace_text={"alpha marker": "translated alpha"},
                ),
            )

            edited = fitz.open(out)
            self.assertEqual(edited.page_count, 2)
            text = "\n".join(page.get_text() for page in edited)
            self.assertIn("translated alpha", text)
            self.assertNotIn("beta marker", text)
            self.assertEqual(edited[0].rotation, 90)
            edited.close()

    def test_edit_options_parse_reorder_and_crop(self):
        from app.pdf_ops import edit_options_from_request

        options = edit_options_from_request({"reorder_pages": "3,1,2", "crop_pages": "1-2", "crop_box": "10,20,300,400"}, 3)

        self.assertEqual(options.reorder_pages, [3, 1, 2])
        self.assertEqual(options.crop_pages, {1: (10.0, 20.0, 300.0, 400.0), 2: (10.0, 20.0, 300.0, 400.0)})

    def test_pdf_edit_applies_reorder_and_crop(self):
        from app.pdf_ops import PdfEditOptions, apply_pdf_edits

        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "source.pdf"
            out = Path(tmp) / "edited.pdf"
            make_pdf(src)

            apply_pdf_edits(src, out, PdfEditOptions(reorder_pages=[3, 1], crop_pages={1: (10.0, 10.0, 300.0, 300.0)}))

            edited = fitz.open(out)
            self.assertEqual(edited.page_count, 2)
            self.assertIn("gamma", edited[0].get_text())
            self.assertEqual(edited[0].cropbox, fitz.Rect(10.0, 10.0, 300.0, 300.0))
            edited.close()

    def test_edit_options_reject_invalid_crop_box(self):
        from app.pdf_ops import edit_options_from_request

        with self.assertRaisesRegex(ValueError, "裁剪区域"):
            edit_options_from_request({"crop_pages": "1", "crop_box": "10,20,5,400"}, 3)

    def test_ocr_rejects_unsupported_input(self):
        from app.ocr import ocr_document

        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "notes.txt"
            source.write_text("plain text", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "OCR supports PDF and image inputs"):
                ocr_document(source, Path(tmp) / "out")

    def test_pdf_searchable_ocr_prefers_ocrmypdf(self):
        from app.ocr import ocr_document

        def fake_run(command, **kwargs):
            Path(command[-1]).write_bytes(b"%PDF-1.7\n")

        with tempfile.TemporaryDirectory() as tmp, patch("app.ocr.shutil.which", side_effect=lambda name: f"/usr/bin/{name}"), patch(
            "app.ocr.run_tracked", side_effect=fake_run
        ) as run:
            root = Path(tmp)
            source = root / "scan.pdf"
            make_pdf(source)
            output = ocr_document(source, root / "out", language="chi_sim+eng")

        command = run.call_args.args[0]
        self.assertEqual(command[0], "ocrmypdf")
        self.assertIn("--skip-text", command)
        self.assertIn("--deskew", command)
        self.assertEqual(output.name, "scan-ocr.pdf")

    def test_pdf_searchable_ocr_keeps_tesseract_fallback(self):
        from app.ocr import ocr_document

        with tempfile.TemporaryDirectory() as tmp, patch("app.ocr.shutil.which", side_effect=lambda name: None if name == "ocrmypdf" else f"/usr/bin/{name}"), patch(
            "app.ocr._ocr_to_searchable_pdf"
        ) as fallback:
            root = Path(tmp)
            source = root / "scan.pdf"
            make_pdf(source)
            output = ocr_document(source, root / "out")

        fallback.assert_called_once_with(source, output, "chi_sim+eng", None)

    def test_pdf_searchable_ocr_falls_back_when_ocrmypdf_fails(self):
        import subprocess

        from app.ocr import ocr_document

        def fake_run(command, **kwargs):
            raise subprocess.CalledProcessError(1, command, stderr="boom")

        with tempfile.TemporaryDirectory() as tmp, patch("app.ocr.shutil.which", side_effect=lambda name: f"/usr/bin/{name}"), patch(
            "app.ocr.run_tracked", side_effect=fake_run
        ), patch("app.ocr._ocr_to_searchable_pdf") as fallback:
            root = Path(tmp)
            source = root / "scan.pdf"
            make_pdf(source)
            output = ocr_document(source, root / "out")

        fallback.assert_called_once_with(source, output, "chi_sim+eng", None)

    def test_markitdown_extraction_enables_plugins(self):
        from app.conversion import extract_markdown

        calls = []

        class FakeMarkItDown:
            def __init__(self, **kwargs):
                calls.append(kwargs)

            def convert(self, source):
                return SimpleNamespace(text_content=f"converted {Path(source).name}")

        with tempfile.TemporaryDirectory() as tmp, patch.dict(
            "sys.modules",
            {"markitdown": SimpleNamespace(MarkItDown=FakeMarkItDown)},
        ):
            source = Path(tmp) / "source.docx"
            source.write_text("stub", encoding="utf-8")
            output = extract_markdown(source, Path(tmp) / "source.md")
            output_text = output.read_text(encoding="utf-8")

        self.assertEqual(output_text, "converted source.docx")
        self.assertEqual(calls, [{"enable_plugins": True}])

    def test_pdf_markdown_extraction_uses_ocr_fallback_when_markitdown_returns_empty_text(self):
        from app.conversion import extract_markdown

        class EmptyMarkItDown:
            def __init__(self, **kwargs):
                pass

            def convert(self, source):
                return SimpleNamespace(text_content="")

        def fake_ocr_markdown(source, output, language):
            output.write_text(f"ocr {source.name} {language}", encoding="utf-8")
            return output

        with tempfile.TemporaryDirectory() as tmp, patch.dict(
            "sys.modules",
            {"markitdown": SimpleNamespace(MarkItDown=EmptyMarkItDown)},
        ), patch("app.conversion.ocr_to_markdown", side_effect=fake_ocr_markdown):
            root = Path(tmp)
            source = root / "scan.pdf"
            make_pdf(source)
            output = extract_markdown(
                source,
                root / "scan.md",
                ocr_fallback=True,
                ocr_language="chi_sim+eng",
            )
            output_text = output.read_text(encoding="utf-8")

        self.assertEqual(output_text, "ocr scan.pdf chi_sim+eng")

    def test_image_markdown_extraction_uses_ocr_without_markitdown(self):
        from app.conversion import extract_markdown

        def fake_ocr_markdown(source, output, language):
            output.write_text(f"image ocr {source.name} {language}", encoding="utf-8")
            return output

        with tempfile.TemporaryDirectory() as tmp, patch("app.conversion.ocr_to_markdown", side_effect=fake_ocr_markdown):
            root = Path(tmp)
            source = root / "scan.png"
            Image.new("RGB", (80, 60), "white").save(source)
            output = extract_markdown(
                source,
                root / "scan.md",
                ocr_fallback=True,
                ocr_language="eng",
            )
            output_text = output.read_text(encoding="utf-8")

        self.assertEqual(output_text, "image ocr scan.png eng")

    def test_markdown_and_html_pdf_conversion_use_playwright_renderer(self):
        from app.conversion import convert_to_pdf

        rendered = []

        def fake_render(source, output):
            rendered.append((source.name, output.name))
            output.write_bytes(b"%PDF-1.7\n")
            return output

        with tempfile.TemporaryDirectory() as tmp, patch("app.conversion.render_browser_pdf", side_effect=fake_render):
            work = Path(tmp)
            markdown = work / "notes.md"
            html = work / "page.html"
            markdown.write_text("# Title", encoding="utf-8")
            html.write_text("<h1>Title</h1>", encoding="utf-8")

            md_pdf = convert_to_pdf(markdown, work / "out")
            html_pdf = convert_to_pdf(html, work / "out")

        self.assertEqual(md_pdf.name, "notes.pdf")
        self.assertEqual(html_pdf.name, "page.pdf")
        self.assertEqual(rendered, [("notes.md", "notes.pdf"), ("page.html", "page.pdf")])

    def test_browser_pdf_renders_data_as_structured_html(self):
        from app.browser_pdf import document_html

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            csv_source = root / "table.csv"
            json_source = root / "payload.json"
            csv_source.write_text("name,value\nalpha,1\nbeta,2\n", encoding="utf-8")
            json_source.write_text('{"name":"alpha","values":[1,2]}', encoding="utf-8")

            csv_html = document_html(csv_source)
            json_html = document_html(json_source)

        self.assertIn("<table", csv_html)
        self.assertIn("<th>name</th>", csv_html)
        self.assertIn("<td>alpha</td>", csv_html)
        self.assertIn("data-kind", json_html)
        self.assertIn("&quot;values&quot;", json_html)

    def test_conversion_delegates_text_inputs_to_browser_pdf_module(self):
        from app.conversion import convert_to_pdf

        rendered = []

        def fake_render(source, output):
            rendered.append((source.name, output.name))
            output.write_bytes(b"%PDF-1.7\n")
            return output

        with tempfile.TemporaryDirectory() as tmp, patch("app.conversion.render_browser_pdf", side_effect=fake_render):
            root = Path(tmp)
            json_source = root / "payload.json"
            json_source.write_text('{"ok": true}', encoding="utf-8")
            result = convert_to_pdf(json_source, root / "out")

        self.assertEqual(result.name, "payload.pdf")
        self.assertEqual(rendered, [("payload.json", "payload.pdf")])

    def test_layout_engine_reports_unavailable_without_babeldoc(self):
        from app.translation import TranslationProvider
        from app.translation_engines import translate_with_layout_engines

        with tempfile.TemporaryDirectory() as tmp, patch("app.translation_engines.babeldoc_available", return_value=False):
            source = Path(tmp) / "source.pdf"
            output = Path(tmp) / "translated.pdf"
            make_pdf(source)
            with self.assertRaisesRegex(RuntimeError, "No layout-preserving"):
                translate_with_layout_engines(
                    source=source,
                    output=output,
                    provider=TranslationProvider("deepseek", "https://api.deepseek.com/v1", "secret", "deepseek-chat"),
                    source_lang="en",
                    target_lang="zh",
                )

    def test_translation_engine_uses_only_babeldoc(self):
        from app.translation import TranslationProvider
        from app.translation_engines import translate_with_layout_engines

        calls = []

        def fake_babeldoc(*args, **kwargs):
            calls.append("babeldoc")
            raise RuntimeError("babeldoc failed")

        with tempfile.TemporaryDirectory() as tmp, patch("app.translation_engines.babeldoc_available", return_value=True), patch(
            "app.translation_engines.translate_with_babeldoc", side_effect=fake_babeldoc
        ):
            root = Path(tmp)
            source = root / "source.pdf"
            output = root / "translated.pdf"
            make_pdf(source)
            with self.assertRaisesRegex(RuntimeError, "BabelDOC"):
                translate_with_layout_engines(
                    source=source,
                    output=output,
                    provider=TranslationProvider("deepseek", "https://api.deepseek.com/v1", "secret", "deepseek-chat"),
                    source_lang="en",
                    target_lang="zh",
                )

        self.assertEqual(calls, ["babeldoc"])

    def test_pdf_translation_uses_layout_engines_before_fallback(self):
        from app.translation import translate_pdf

        with tempfile.TemporaryDirectory() as tmp, patch.dict(
            os.environ, {"DEEPSEEK_API_KEY": "sk-test"}, clear=False
        ), patch("app.translation.translate_with_layout_engines") as layout_engines:
            source = Path(tmp) / "source.pdf"
            output = Path(tmp) / "translated.pdf"
            make_pdf(source)
            layout_engines.return_value = output

            result = translate_pdf(source, output, "deepseek", "en", "zh", output_mode="translated", glossary="")

        self.assertEqual(result, output)
        layout_engines.assert_called_once()

    def test_pdf_translation_logs_layout_fallback_reason(self):
        from app.translation import translate_pdf

        fallbacks: list[str] = []

        with tempfile.TemporaryDirectory() as tmp, patch.dict(
            os.environ, {"DEEPSEEK_API_KEY": "sk-test"}, clear=False
        ), patch(
            "app.translation.translate_with_layout_engines", side_effect=RuntimeError("babeldoc boom")
        ), patch("app.translation.translate_text", return_value="译文"):
            source = Path(tmp) / "source.pdf"
            output = Path(tmp) / "translated.pdf"
            make_pdf(source)
            result = translate_pdf(source, output, "deepseek", "en", "zh", on_layout_fallback=fallbacks.append)

        self.assertEqual(result, output)
        self.assertTrue(any("babeldoc boom" in item for item in fallbacks))

    def test_pdf_edit_merge_preserves_upload_order(self):
        from app.jobs import JobStore
        from app.main import run_job

        with tempfile.TemporaryDirectory() as tmp, patch("app.main.merge_pdfs") as merge:
            root = Path(tmp)
            store = JobStore(root, ttl_hours=24)
            job = store.create("pdf_edit", ["b.pdf", "a.pdf", "c.pdf"], {"action": "merge"})
            upload_dir = job.path / "uploads"
            upload_dir.mkdir()
            for name in ("a.pdf", "b.pdf", "c.pdf"):
                (upload_dir / name).write_bytes(b"%PDF-1.7\n")
            merged = root / "merged.pdf"
            merge.return_value = merged

            run_job(store, job.id)

            merged_sources = [path.name for path in merge.call_args.args[0]]
            self.assertEqual(merged_sources, ["b.pdf", "a.pdf", "c.pdf"])

    def test_error_classification_uses_exception_types(self):
        from app.errors import (
            MissingDependency,
            NoUploadedFiles,
            OcrInputRequired,
            PdfInputRequired,
            ProviderNotConfigured,
        )
        from app.main import classify_error

        self.assertEqual(classify_error(PdfInputRequired("x"))["code"], "pdf_input_required")
        self.assertEqual(classify_error(OcrInputRequired("x"))["code"], "ocr_input_required")
        self.assertEqual(classify_error(NoUploadedFiles("x"))["code"], "file_required")
        self.assertEqual(classify_error(ProviderNotConfigured("x"))["code"], "missing_provider")
        dependency = classify_error(MissingDependency("x", "brew install tesseract"))
        self.assertEqual(dependency["code"], "missing_dependency")
        self.assertEqual(dependency["hint"], "brew install tesseract")
        self.assertEqual(classify_error(RuntimeError("random"))["code"], "task_failed")

    def test_cancel_kills_tracked_subprocess(self):
        import subprocess
        import threading
        import time

        from app.processes import kill_thread_processes, run_tracked

        outcome: dict[str, object] = {}

        def worker() -> None:
            try:
                run_tracked(["sleep", "30"], timeout=60, check=True)
            except subprocess.SubprocessError as exc:
                outcome["exc"] = exc

        thread = threading.Thread(target=worker)
        thread.start()
        time.sleep(0.3)
        kill_thread_processes(thread.ident)
        thread.join(timeout=5)

        self.assertIn("exc", outcome)

    def test_cancel_running_job_kills_its_subprocess(self):
        import subprocess
        import threading
        import time

        from app.jobs import JobStore
        from app.processes import run_tracked

        outcome: dict[str, object] = {}

        def worker() -> None:
            try:
                run_tracked(["sleep", "30"], timeout=60, check=True)
            except subprocess.SubprocessError as exc:
                outcome["exc"] = exc

        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp), ttl_hours=24)
            job = store.create("ocr", ["scan.pdf"])
            thread = threading.Thread(target=worker)
            thread.start()
            time.sleep(0.3)
            job.thread_id = thread.ident
            store.save(job)
            store.request_cancel(job.id)
            thread.join(timeout=5)

        self.assertIn("exc", outcome)

    def test_tracked_process_redacts_sensitive_values_from_results_and_errors(self):
        import subprocess
        import sys

        from app.processes import run_tracked

        secret = "sk-secret-never-log"
        command = [
            sys.executable,
            "-c",
            "import sys; value=sys.stdin.read(); print(value); print(value, file=sys.stderr); raise SystemExit(2)",
        ]
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            run_tracked(command, timeout=5, check=True, stdin_text=secret, sensitive_values=(secret,))

        error = caught.exception
        self.assertNotIn(secret, str(error))
        self.assertNotIn(secret, str(error.cmd))
        self.assertNotIn(secret, error.stdout)
        self.assertNotIn(secret, error.stderr)
        self.assertIn("[REDACTED]", error.stdout)
        self.assertIn("[REDACTED]", error.stderr)

    def test_babeldoc_key_is_passed_through_stdin_not_process_arguments(self):
        from app.translation import TranslationProvider
        from app.translation_engines import translate_with_babeldoc

        secret = "sk-layout-secret"
        provider = TranslationProvider("deepseek", "https://api.deepseek.com/v1", secret, "deepseek-chat")
        with tempfile.TemporaryDirectory() as tmp, patch("app.translation_engines.run_tracked") as run:
            root = Path(tmp)
            source = root / "report.pdf"
            source.write_bytes(b"%PDF-1.7\n")
            generated = root / "report-dual.pdf"
            generated.write_bytes(b"%PDF-1.7\n")
            output = root / "translated.pdf"

            result = translate_with_babeldoc(source, output, provider, "en", "zh", output_mode="bilingual")

        self.assertEqual(result, output)
        command = run.call_args.args[0]
        self.assertNotIn(secret, command)
        self.assertNotIn("--openai-api-key", command)
        self.assertIn(secret, run.call_args.kwargs["stdin_text"])
        self.assertEqual(run.call_args.kwargs["sensitive_values"], (secret,))

    def test_babeldoc_adapter_errors_do_not_expose_api_key(self):
        from app.translation import TranslationProvider
        from app.translation_engines import translate_with_layout_engines

        secret = "sk-layout-secret"
        provider = TranslationProvider("deepseek", "https://api.deepseek.com/v1", secret, "deepseek-chat")
        with tempfile.TemporaryDirectory() as tmp, patch(
            "app.translation_engines.babeldoc_available", return_value=True
        ), patch("app.translation_engines.translate_with_babeldoc", side_effect=RuntimeError(f"failed with {secret}")):
            source = Path(tmp) / "source.pdf"
            source.write_bytes(b"%PDF-1.7\n")

            with self.assertRaises(RuntimeError) as caught:
                translate_with_layout_engines(source, Path(tmp) / "output.pdf", provider, "en", "zh")

        self.assertNotIn(secret, str(caught.exception))
        self.assertIn("[REDACTED]", str(caught.exception))

    def test_browser_xml_renderer_does_not_expand_entities(self):
        from app.browser_pdf import document_html

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            secret_file = root / "secret.txt"
            secret_file.write_text("should-not-be-expanded", encoding="utf-8")
            source = root / "payload.xml"
            source.write_text(
                f'<!DOCTYPE root [<!ENTITY xxe SYSTEM "{secret_file.as_uri()}">]><root>&xxe;</root>',
                encoding="utf-8",
            )

            rendered = document_html(source)

        self.assertNotIn("should-not-be-expanded", rendered)
        self.assertIn("&amp;xxe;", rendered)

    def test_browser_renderer_rejects_text_over_configured_limit(self):
        from app.browser_pdf import document_html

        with tempfile.TemporaryDirectory() as tmp, patch("app.browser_pdf.MAX_BROWSER_TEXT_BYTES", 4), patch(
            "app.browser_pdf.MAX_BROWSER_TEXT_MB", 1
        ):
            source = Path(tmp) / "large.txt"
            source.write_bytes(b"12345")

            with self.assertRaisesRegex(ValueError, "1 MB renderer limit"):
                document_html(source)

    def test_pdf_translation_fallback_translates_pages_concurrently(self):
        import threading
        import time

        from app.translation import translate_pdf

        active = 0
        peak = 0
        lock = threading.Lock()

        def fake_translate(provider, text, source_lang, target_lang, glossary=""):
            nonlocal active, peak
            with lock:
                active += 1
                peak = max(peak, active)
            time.sleep(0.08)
            with lock:
                active -= 1
            return f"t:{text}"

        progress: list[tuple[int, int]] = []

        with tempfile.TemporaryDirectory() as tmp, patch.dict(
            os.environ, {"DEEPSEEK_API_KEY": "sk-test"}, clear=False
        ), patch("app.translation.translate_with_layout_engines", side_effect=RuntimeError("x")), patch(
            "app.translation.translate_text", side_effect=fake_translate
        ):
            source = Path(tmp) / "source.pdf"
            output = Path(tmp) / "translated.pdf"
            make_pdf(source)
            result = translate_pdf(source, output, "deepseek", "en", "zh", on_progress=lambda done, total: progress.append((done, total)))

            self.assertEqual(result, output)
            with fitz.open(output) as doc:
                self.assertIn("t:", doc[0].get_text())

        self.assertGreater(peak, 1)
        self.assertEqual(progress, [(1, 3), (2, 3), (3, 3)])

    def test_translate_text_retries_transient_failures(self):
        import httpx

        from app.translation import TranslationProvider, translate_text

        attempts: list[int] = []

        class FakeResponse:
            def __init__(self, status_code: int) -> None:
                self.status_code = status_code

            def raise_for_status(self) -> None:
                if self.status_code >= 400:
                    raise httpx.HTTPStatusError(
                        f"HTTP {self.status_code}",
                        request=httpx.Request("POST", "https://api.deepseek.com/v1/chat/completions"),
                        response=httpx.Response(self.status_code),
                    )

            def json(self) -> dict[str, object]:
                return {"choices": [{"message": {"content": "译文"}}]}

        class FakeClient:
            def __init__(self, *args, **kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def post(self, *args, **kwargs):
                attempts.append(1)
                return FakeResponse(200 if len(attempts) >= 3 else 429)

        provider = TranslationProvider("deepseek", "https://api.deepseek.com/v1", "sk-test", "deepseek-chat")
        with patch("httpx.Client", FakeClient), patch("app.translation.time.sleep"):
            result = translate_text(provider, "hello", "en", "zh")

        self.assertEqual(result, "译文")
        self.assertEqual(len(attempts), 3)

    def test_babeldoc_output_finder_ignores_stale_files(self):
        import time

        from app.translation_engines import _find_babeldoc_output

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stale = root / "report-zh.pdf"
            stale.write_bytes(b"%PDF-1.7\n")
            os.utime(stale, (1_000_000, 1_000_000))
            fresh = root / "report-translated.pdf"
            fresh.write_bytes(b"%PDF-1.7\n")

            found = _find_babeldoc_output(root, "report", "translated", since=time.time())

        self.assertEqual(found, fresh)

    def test_glossary_csv_quotes_commas(self):
        import csv

        from app.translation_engines import _write_glossary_csv

        path = _write_glossary_csv("hello, world => 你好，世界")
        try:
            with open(path, encoding="utf-8") as handle:
                rows = list(csv.reader(handle))
        finally:
            path.unlink(missing_ok=True)

        self.assertEqual(rows[0], ["source", "target"])
        self.assertEqual(rows[1], ["hello", "world => 你好，世界"])

    def test_readme_documents_ocr_and_enhanced_engines(self):
        root = Path(__file__).resolve().parents[1]
        readme = (root / "README.md").read_text(encoding="utf-8")
        requirements = (root / "requirements.txt").read_text(encoding="utf-8")
        optional_requirements = (root / "requirements-optional.txt").read_text(encoding="utf-8")

        self.assertNotIn("No OCR in v1", readme)
        self.assertIn("OCR", readme)
        self.assertIn("Playwright", readme)
        self.assertNotIn("pdf2zh", readme)
        self.assertIn("BabelDOC", readme)
        self.assertIn("External Engine Policy", readme)
        self.assertIn("AGPL", readme)
        self.assertIn("requirements-optional.txt", readme)
        self.assertNotIn("markitdown[all]", requirements)
        self.assertNotIn("BabelDOC", requirements)
        self.assertNotIn("pdf2zh", requirements)
        self.assertIn("markitdown[all]", optional_requirements)
        self.assertIn("BabelDOC", optional_requirements)
        self.assertNotIn("pdf2zh", optional_requirements)


if __name__ == "__main__":
    unittest.main()
