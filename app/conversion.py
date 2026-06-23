from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from PIL import Image

from .config import HTML_EXTENSIONS, IMAGE_EXTENSIONS, MARKDOWN_EXTENSIONS, OFFICE_EXTENSIONS, PDF_EXTENSIONS, TEXT_EXTENSIONS
from .browser_pdf import render_browser_pdf


def convert_to_pdf(source: Path, output_dir: Path) -> Path:
    ext = source.suffix.lower()
    output_dir.mkdir(parents=True, exist_ok=True)
    if ext in PDF_EXTENSIONS:
        target = output_dir / source.name
        shutil.copy2(source, target)
        return target
    if ext in OFFICE_EXTENSIONS:
        return _libreoffice_to_pdf(source, output_dir)
    if ext in MARKDOWN_EXTENSIONS or ext in HTML_EXTENSIONS or ext in TEXT_EXTENSIONS:
        return render_browser_pdf(source, output_dir / f"{source.stem}.pdf")
    if ext in IMAGE_EXTENSIONS:
        return _image_to_pdf(source, output_dir / f"{source.stem}.pdf")
    raise ValueError(f"Unsupported input for PDF conversion: {source.suffix}")


def extract_markdown(source: Path, output: Path) -> Path:
    try:
        from markitdown import MarkItDown
    except Exception as exc:
        raise RuntimeError("MarkItDown is not installed. Run: pip install -r requirements.txt") from exc
    md = MarkItDown(enable_plugins=True)
    result = md.convert(str(source))
    text = getattr(result, "text_content", None) or getattr(result, "markdown", "")
    output.write_text(text, encoding="utf-8")
    return output


def _libreoffice_to_pdf(source: Path, output_dir: Path) -> Path:
    soffice = shutil.which("soffice")
    if not soffice:
        raise RuntimeError("LibreOffice command `soffice` was not found")
    subprocess.run(
        [soffice, "--headless", "--convert-to", "pdf", "--outdir", str(output_dir), str(source)],
        check=True,
        capture_output=True,
        text=True,
        timeout=120,
    )
    target = output_dir / f"{source.stem}.pdf"
    if not target.exists():
        matches = list(output_dir.glob("*.pdf"))
        if not matches:
            raise RuntimeError("LibreOffice did not produce a PDF")
        return matches[0]
    return target


def _image_to_pdf(source: Path, output: Path) -> Path:
    image = Image.open(source).convert("RGB")
    image.save(output, "PDF", resolution=150.0)
    return output
