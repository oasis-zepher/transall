from __future__ import annotations

import shutil
from pathlib import Path

import fitz
from PIL import Image

from .config import IMAGE_EXTENSIONS, PDF_EXTENSIONS


def ocr_document(
    source: Path,
    output_dir: Path,
    language: str = "chi_sim+eng",
    output_format: str = "searchable_pdf",
) -> Path:
    ext = source.suffix.lower()
    if ext not in PDF_EXTENSIONS and ext not in IMAGE_EXTENSIONS:
        raise ValueError("OCR supports PDF and image inputs")
    if output_format not in {"searchable_pdf", "text"}:
        raise ValueError("OCR output_format must be searchable_pdf or text")

    _ensure_tesseract_available()
    output_dir.mkdir(parents=True, exist_ok=True)

    if output_format == "text":
        output = output_dir / f"{source.stem}-ocr.txt"
        output.write_text(_ocr_to_text(source, language), encoding="utf-8")
        return output

    output = output_dir / f"{source.stem}-ocr.pdf"
    _ocr_to_searchable_pdf(source, output, language)
    return output


def ocr_to_markdown(source: Path, output: Path, language: str = "chi_sim+eng") -> Path:
    ext = source.suffix.lower()
    if ext not in PDF_EXTENSIONS and ext not in IMAGE_EXTENSIONS:
        raise ValueError("OCR Markdown fallback supports PDF and image inputs")
    _ensure_tesseract_available()
    output.parent.mkdir(parents=True, exist_ok=True)
    text = _ocr_to_text(source, language).strip()
    output.write_text(text + ("\n" if text else ""), encoding="utf-8")
    return output


def _ensure_tesseract_available() -> None:
    if not shutil.which("tesseract"):
        raise RuntimeError("OCR requires Tesseract. Install it on macOS with: brew install tesseract")
    try:
        import pytesseract  # noqa: F401
    except Exception as exc:
        raise RuntimeError("OCR requires pytesseract. Install Python dependencies with: pip install -r requirements.txt") from exc


def _ocr_to_text(source: Path, language: str) -> str:
    chunks: list[str] = []
    for index, image in enumerate(_iter_page_images(source), start=1):
        text = _ocr_image_to_text(image, language).strip()
        if text:
            chunks.append(f"## Page {index}\n\n{text}")
    return "\n\n".join(chunks).strip() + "\n"


def _ocr_to_searchable_pdf(source: Path, output: Path, language: str) -> None:
    target = fitz.open()
    try:
        for image in _iter_page_images(source):
            page_pdf = _ocr_image_to_pdf(image, language)
            with fitz.open(stream=page_pdf, filetype="pdf") as page_doc:
                target.insert_pdf(page_doc)
        if target.page_count == 0:
            raise ValueError("OCR produced no pages")
        target.save(output)
    finally:
        target.close()


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
