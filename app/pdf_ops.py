from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import fitz


@dataclass
class PdfEditOptions:
    delete_pages: list[int] = field(default_factory=list)
    rotate_pages: dict[int, int] = field(default_factory=dict)
    replace_text: dict[str, str] = field(default_factory=dict)
    reorder_pages: list[int] = field(default_factory=list)
    crop_pages: dict[int, tuple[float, float, float, float]] = field(default_factory=dict)
    watermark: str | None = None


def parse_page_spec(spec: str | None, page_count: int) -> list[int]:
    if page_count < 1:
        return []
    if not spec or not spec.strip():
        return list(range(1, page_count + 1))
    pages: set[int] = set()
    for raw_part in spec.split(","):
        part = raw_part.strip()
        if not part:
            continue
        if "-" in part:
            start_text, end_text = part.split("-", 1)
            start = int(start_text) if start_text else 1
            end = int(end_text) if end_text else page_count
            if start > end:
                start, end = end, start
            pages.update(range(max(1, start), min(page_count, end) + 1))
        else:
            page = int(part)
            if 1 <= page <= page_count:
                pages.add(page)
    return sorted(pages)


def parse_page_order(spec: str | None, page_count: int) -> list[int]:
    """Order-preserving page list for reorder: input order is the new page order."""
    if not spec or not spec.strip():
        return []
    pages: list[int] = []
    for raw_part in spec.split(","):
        part = raw_part.strip()
        if not part:
            continue
        if "-" in part:
            start_text, end_text = part.split("-", 1)
            start = int(start_text) if start_text else 1
            end = int(end_text) if end_text else page_count
            if start <= end:
                pages.extend(range(start, end + 1))
            else:
                pages.extend(range(start, end - 1, -1))
        else:
            pages.append(int(part))
    return [page for page in pages if 1 <= page <= page_count]


def pdf_page_count(source: Path) -> int:
    with fitz.open(source) as doc:
        return doc.page_count


def edit_options_from_request(options: dict[str, Any], page_count: int) -> PdfEditOptions:
    delete_pages = parse_page_spec(options.get("delete_pages", ""), page_count) if options.get("delete_pages") else []
    rotate_pages = {
        page: int(options.get("rotate_degrees", 90))
        for page in parse_page_spec(options.get("rotate_pages", ""), page_count)
    }
    reorder_pages = parse_page_order(options.get("reorder_pages", ""), page_count) if options.get("reorder_pages") else []
    crop_pages: dict[int, tuple[float, float, float, float]] = {}
    if options.get("crop_pages"):
        box = _parse_crop_box(str(options.get("crop_box", "")))
        crop_pages = {page: box for page in parse_page_spec(str(options["crop_pages"]), page_count)}
    replace_text = {}
    if options.get("replace_find"):
        replace_text[str(options["replace_find"])] = str(options.get("replace_with", ""))
    return PdfEditOptions(
        delete_pages=delete_pages,
        rotate_pages=rotate_pages,
        reorder_pages=reorder_pages,
        crop_pages=crop_pages,
        replace_text=replace_text,
        watermark=options.get("watermark") or None,
    )


def _parse_crop_box(spec: str) -> tuple[float, float, float, float]:
    parts = [part.strip() for part in spec.split(",")]
    if len(parts) != 4:
        raise ValueError("裁剪区域需要四个数字，格式为 x0,y0,x1,y1（PDF 点，72 点/英寸）")
    try:
        x0, y0, x1, y1 = (float(part) for part in parts)
    except ValueError as exc:
        raise ValueError("裁剪区域需要四个数字，格式为 x0,y0,x1,y1（PDF 点，72 点/英寸）") from exc
    if x0 >= x1 or y0 >= y1:
        raise ValueError("裁剪区域需要满足 x0 < x1 且 y0 < y1")
    return (x0, y0, x1, y1)


def apply_pdf_edits(source: Path, output: Path, options: PdfEditOptions) -> Path:
    doc = fitz.open(source)
    try:
        if options.reorder_pages:
            reordered = fitz.open()
            for page_no in options.reorder_pages:
                if 1 <= page_no <= doc.page_count:
                    reordered.insert_pdf(doc, from_page=page_no - 1, to_page=page_no - 1)
            doc.close()
            doc = reordered

        for page_no in sorted(options.delete_pages, reverse=True):
            if 1 <= page_no <= doc.page_count:
                doc.delete_page(page_no - 1)

        for page_no, angle in options.rotate_pages.items():
            if 1 <= page_no <= doc.page_count:
                doc[page_no - 1].set_rotation(angle % 360)

        for page_no, box in options.crop_pages.items():
            if 1 <= page_no <= doc.page_count:
                doc[page_no - 1].set_cropbox(fitz.Rect(*box))

        if options.watermark:
            for page in doc:
                rect = page.rect
                page.insert_text(
                    (rect.width * 0.18, rect.height * 0.52),
                    options.watermark,
                    fontsize=32,
                    rotate=25,
                    color=(0.75, 0.12, 0.12),
                    fill_opacity=0.18,
                )

        for old, new in options.replace_text.items():
            if not old:
                continue
            replaced = False
            for page in doc:
                hits = page.search_for(old)
                for rect in hits:
                    page.add_redact_annot(rect, fill=(1, 1, 1))
                if hits:
                    page.apply_redactions()
                    for rect in hits:
                        page.insert_textbox(rect + (-1, -1, 120, 8), new, fontsize=max(8, rect.height * 0.72), color=(0, 0, 0))
                    replaced = True
            if not replaced:
                raise ValueError(f"Text not found in PDF: {old}")

        output.parent.mkdir(parents=True, exist_ok=True)
        doc.save(output, garbage=4, deflate=True)
        return output
    finally:
        doc.close()


def merge_pdfs(sources: list[Path], output: Path) -> Path:
    target = fitz.open()
    try:
        for source in sources:
            with fitz.open(source) as doc:
                target.insert_pdf(doc)
        output.parent.mkdir(parents=True, exist_ok=True)
        target.save(output, garbage=4, deflate=True)
        return output
    finally:
        target.close()


def render_preview_pages(source: Path, out_dir: Path, max_pages: int = 12) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    rendered: list[Path] = []
    with fitz.open(source) as doc:
        for index in range(min(doc.page_count, max_pages)):
            pix = doc[index].get_pixmap(matrix=fitz.Matrix(0.35, 0.35), alpha=False)
            path = out_dir / f"page-{index + 1}.png"
            pix.save(path)
            rendered.append(path)
    return rendered
