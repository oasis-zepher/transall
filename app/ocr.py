from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import Callable

import fitz
from PIL import Image

from .config import IMAGE_EXTENSIONS, PDF_EXTENSIONS
from .errors import MissingDependency, OcrInputRequired
from .processes import run_tracked


def ocr_document(
    source: Path,
    output_dir: Path,
    language: str = "chi_sim+eng",
    output_format: str = "searchable_pdf",
    cancel_check: Callable[[], None] | None = None,
) -> Path:
    ext = source.suffix.lower()
    if ext not in PDF_EXTENSIONS and ext not in IMAGE_EXTENSIONS:
        raise OcrInputRequired("OCR supports PDF and image inputs")
    if output_format not in {"searchable_pdf", "text"}:
        raise ValueError("OCR output_format must be searchable_pdf or text")

    _ensure_tesseract_available()
    output_dir.mkdir(parents=True, exist_ok=True)

    if output_format == "text":
        output = output_dir / f"{source.stem}-ocr.txt"
        output.write_text(_ocr_to_text(source, language, cancel_check), encoding="utf-8")
        return output

    output = output_dir / f"{source.stem}-ocr.pdf"
    if ext in PDF_EXTENSIONS and shutil.which("ocrmypdf"):
        try:
            _ocr_pdf_with_ocrmypdf(source, output, language)
            return output
        except Exception:
            if cancel_check is not None:
                cancel_check()
    _ocr_to_searchable_pdf(source, output, language, cancel_check)
    return output


def ocr_to_markdown(source: Path, output: Path, language: str = "chi_sim+eng") -> Path:
    ext = source.suffix.lower()
    if ext not in PDF_EXTENSIONS and ext not in IMAGE_EXTENSIONS:
        raise OcrInputRequired("OCR Markdown fallback supports PDF and image inputs")
    _ensure_tesseract_available()
    output.parent.mkdir(parents=True, exist_ok=True)
    text = _ocr_to_text(source, language).strip()
    output.write_text(text + ("\n" if text else ""), encoding="utf-8")
    return output


def _ensure_tesseract_available() -> None:
    if not shutil.which("tesseract"):
        raise MissingDependency(
            "OCR requires Tesseract. Install it on macOS with: brew install tesseract",
            "brew install tesseract tesseract-lang 后重启服务。",
        )
    try:
        import pytesseract  # noqa: F401
    except Exception as exc:
        raise MissingDependency(
            "OCR requires pytesseract. Install Python dependencies with: pip install -r requirements.txt",
            "python -m pip install -r requirements.txt 后重启服务。",
        ) from exc


def _ocr_to_text(source: Path, language: str, cancel_check: Callable[[], None] | None = None) -> str:
    chunks: list[str] = []
    for index, image in enumerate(_iter_page_images(source), start=1):
        if cancel_check is not None:
            cancel_check()
        text = _ocr_image_to_text(image, language).strip()
        if text:
            chunks.append(f"## Page {index}\n\n{text}")
    return "\n\n".join(chunks).strip() + "\n"


def _ocr_to_searchable_pdf(source: Path, output: Path, language: str, cancel_check: Callable[[], None] | None = None) -> None:
    target = fitz.open()
    try:
        for image in _iter_page_images(source):
            if cancel_check is not None:
                cancel_check()
            page_pdf = _ocr_image_to_pdf(image, language)
            with fitz.open(stream=page_pdf, filetype="pdf") as page_doc:
                target.insert_pdf(page_doc)
        if target.page_count == 0:
            raise ValueError("OCR produced no pages")
        target.save(output)
    finally:
        target.close()


def _ocr_pdf_with_ocrmypdf(source: Path, output: Path, language: str) -> None:
    command = [
        "ocrmypdf",
        "--language",
        language,
        "--skip-text",
        "--rotate-pages",
        "--deskew",
        "--jobs",
        "2",
        "--output-type",
        "pdf",
        str(source),
        str(output),
    ]
    try:
        run_tracked(command, 900, check=True)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("OCRmyPDF timed out after 15 minutes") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "OCRmyPDF failed").strip()
        raise RuntimeError(f"OCRmyPDF failed: {detail}") from exc
    if not output.exists():
        raise RuntimeError("OCRmyPDF did not produce a PDF")


def _iter_page_images(source: Path):
    ext = source.suffix.lower()
    if ext in IMAGE_EXTENSIONS:
        with Image.open(source) as image:
            yield image.convert("RGB")
        return

    with fitz.open(source) as doc:
        for page in doc:
            pix = page.get_pixmap(matrix=fitz.Matrix(2, 2), alpha=False)
            image = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
            yield image


def _ocr_image_to_text(image: Image.Image, language: str) -> str:
    import pytesseract

    return pytesseract.image_to_string(image, lang=language)


def _ocr_image_to_pdf(image: Image.Image, language: str) -> bytes:
    import pytesseract

    return pytesseract.image_to_pdf_or_hocr(image, lang=language, extension="pdf")
