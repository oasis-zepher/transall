import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

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

    def test_ocr_rejects_unsupported_input(self):
        from app.ocr import ocr_document

        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "notes.txt"
            source.write_text("plain text", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "OCR supports PDF and image inputs"):
                ocr_document(source, Path(tmp) / "out")

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

    def test_layout_engine_can_use_pdf2zh_when_babeldoc_is_unavailable(self):
        from app.translation_engines import translate_with_layout_engines
        from app.translation import TranslationProvider

        with tempfile.TemporaryDirectory() as tmp, patch("app.translation_engines.babeldoc_available", return_value=False), patch(
            "app.translation_engines.pdf2zh_available", return_value=True
        ), patch("app.translation_engines.translate_with_pdf2zh") as translate_with_pdf2zh:
            source = Path(tmp) / "source.pdf"
            output = Path(tmp) / "translated.pdf"
            make_pdf(source)
            translate_with_pdf2zh.return_value = output

            result = translate_with_layout_engines(
                source=source,
                output=output,
                provider=TranslationProvider("deepseek", "https://api.deepseek.com/v1", "secret", "deepseek-chat"),
                source_lang="en",
                target_lang="zh",
                output_mode="translated",
                glossary="",
            )

        self.assertEqual(result, output)
        translate_with_pdf2zh.assert_called_once()

    def test_translation_engine_order_prefers_babeldoc_then_pdf2zh(self):
        from app.translation_engines import translate_with_layout_engines
        from app.translation import TranslationProvider

        calls = []

        def fake_babeldoc(*args, **kwargs):
            calls.append("babeldoc")
            raise RuntimeError("babeldoc failed")

        def fake_pdf2zh(*args, **kwargs):
            calls.append("pdf2zh")
            output = kwargs["output"]
            output.write_bytes(b"%PDF-1.7\n")
            return output

        with tempfile.TemporaryDirectory() as tmp, patch("app.translation_engines.babeldoc_available", return_value=True), patch(
            "app.translation_engines.pdf2zh_available", return_value=True
        ), patch("app.translation_engines.translate_with_babeldoc", side_effect=fake_babeldoc), patch(
            "app.translation_engines.translate_with_pdf2zh", side_effect=fake_pdf2zh
        ):
            root = Path(tmp)
            source = root / "source.pdf"
            output = root / "translated.pdf"
            make_pdf(source)
            result = translate_with_layout_engines(
                source=source,
                output=output,
                provider=TranslationProvider("deepseek", "https://api.deepseek.com/v1", "secret", "deepseek-chat"),
                source_lang="en",
                target_lang="zh",
                pages_spec="",
                output_mode="translated",
                glossary="",
            )

        self.assertEqual(result, output)
        self.assertEqual(calls, ["babeldoc", "pdf2zh"])

    def test_pdf_translation_uses_layout_engines_before_fallback(self):
        from app.translation import translate_pdf

        with tempfile.TemporaryDirectory() as tmp, patch("app.translation.translate_with_layout_engines") as layout_engines:
            source = Path(tmp) / "source.pdf"
            output = Path(tmp) / "translated.pdf"
            make_pdf(source)
            layout_engines.return_value = output

            result = translate_pdf(source, output, "deepseek", "en", "zh", output_mode="translated", glossary="")

        self.assertEqual(result, output)
        layout_engines.assert_called_once()

    def test_readme_documents_ocr_and_enhanced_engines(self):
        root = Path(__file__).resolve().parents[1]
        readme = (root / "README.md").read_text(encoding="utf-8")
        requirements = (root / "requirements.txt").read_text(encoding="utf-8")
        optional_requirements = (root / "requirements-optional.txt").read_text(encoding="utf-8")

        self.assertNotIn("No OCR in v1", readme)
        self.assertIn("OCR", readme)
        self.assertIn("Playwright", readme)
        self.assertIn("pdf2zh", readme)
        self.assertIn("BabelDOC", readme)
        self.assertIn("External Engine Policy", readme)
        self.assertIn("AGPL", readme)
        self.assertIn("requirements-optional.txt", readme)
        self.assertNotIn("markitdown[all]", requirements)
        self.assertNotIn("BabelDOC", requirements)
        self.assertNotIn("pdf2zh", requirements)
        self.assertIn("markitdown[all]", optional_requirements)
        self.assertIn("BabelDOC", optional_requirements)
        self.assertIn("pdf2zh==1.7.9", optional_requirements)


if __name__ == "__main__":
    unittest.main()
