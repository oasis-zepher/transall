#!/usr/bin/env python3

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A4
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas


PROJECT_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = PROJECT_ROOT / "output" / "pdf" / "review-samples"
TEMP_DIR = PROJECT_ROOT / "tmp" / "pdfs"

PAPER = HexColor("#F7F6F0")
INK = HexColor("#262A27")
INK_SOFT = HexColor("#555C57")
MUTED = HexColor("#68716B")
LINE = HexColor("#BEC3B9")
ACCENT = HexColor("#B94E38")
SOURCE = HexColor("#376F53")


def setup_page(pdf: canvas.Canvas, title: str, index: str) -> None:
    width, height = A4
    pdf.setFillColor(PAPER)
    pdf.rect(0, 0, width, height, stroke=0, fill=1)
    pdf.setStrokeColor(HexColor("#E4E5DE"))
    pdf.setLineWidth(0.35)
    step = 28
    for x in range(0, int(width) + step, step):
        pdf.line(x, 0, x, height)
    for y in range(0, int(height) + step, step):
        pdf.line(0, y, width, y)

    pdf.setFillColor(MUTED)
    pdf.setFont("Helvetica-Bold", 8)
    pdf.drawString(48, height - 44, "TRANSALL REVIEW SAMPLE")
    pdf.drawRightString(width - 48, height - 44, index)
    pdf.setStrokeColor(LINE)
    pdf.line(48, height - 54, width - 48, height - 54)
    pdf.setFillColor(INK)
    pdf.setFont("Times-Bold", 24)
    pdf.drawString(48, height - 92, title)


def footer(pdf: canvas.Canvas, page_number: int) -> None:
    width, _ = A4
    pdf.setStrokeColor(LINE)
    pdf.line(48, 42, width - 48, 42)
    pdf.setFillColor(MUTED)
    pdf.setFont("Helvetica", 7.5)
    pdf.drawString(48, 28, "Synthetic document - safe for screenshots and App Review")
    pdf.drawRightString(width - 48, 28, f"PAGE {page_number:02d}")


def draw_paragraph(pdf: canvas.Canvas, lines: list[str], x: float, y: float, leading: float = 16) -> float:
    text = pdf.beginText(x, y)
    text.setFont("Helvetica", 10.5)
    text.setFillColor(INK_SOFT)
    text.setLeading(leading)
    for line in lines:
        text.textLine(line)
    pdf.drawText(text)
    return y - leading * len(lines)


def draw_section(pdf: canvas.Canvas, label: str, title: str, lines: list[str], y: float) -> float:
    pdf.setFillColor(ACCENT)
    pdf.setFont("Helvetica-Bold", 7.5)
    pdf.drawString(48, y, label.upper())
    pdf.setFillColor(INK)
    pdf.setFont("Times-Bold", 15)
    pdf.drawString(48, y - 24, title)
    return draw_paragraph(pdf, lines, 48, y - 48) - 25


def research_notes(path: Path) -> None:
    pdf = canvas.Canvas(str(path), pagesize=A4)
    pdf.setTitle("Research Notes")
    pdf.setAuthor("Transall synthetic review sample")

    setup_page(pdf, "Document Routing Notes", "01 / NOTES")
    y = 700
    y = draw_section(
        pdf,
        "Question",
        "How should a local document workflow expose each processing step?",
        [
            "The workflow should show the selected input, operation, result, and recovery path.",
            "Files remain local unless the user explicitly starts a translation request.",
        ],
        y,
    )
    y = draw_section(
        pdf,
        "Method",
        "Compare repeatable tasks across three document types",
        [
            "1. Merge two short PDF notes and preserve their page order.",
            "2. Run OCR on an image-only scan and inspect the searchable result.",
            "3. Translate a short English sample with an explicitly selected provider.",
        ],
        y,
    )
    y = draw_section(
        pdf,
        "Observation",
        "Visible state reduces uncertainty",
        [
            "A compact route selector keeps the current source and target formats visible.",
            "Logs should state which local framework performed the work and where recovery starts.",
        ],
        y,
    )
    footer(pdf, 1)
    pdf.showPage()

    setup_page(pdf, "Review Checklist", "02 / CHECK")
    rows = [
        ("Input", "Synthetic files only", SOURCE),
        ("Privacy", "No identifiers or credentials", SOURCE),
        ("Failure", "Actionable message and retry path", ACCENT),
        ("Result", "New file; source remains unchanged", SOURCE),
        ("Cleanup", "Local task data removable on demand", SOURCE),
    ]
    y = 690
    for index, (label, value, color) in enumerate(rows, start=1):
        pdf.setStrokeColor(LINE)
        pdf.setFillColor(HexColor("#FBFAF6"))
        pdf.roundRect(48, y - 42, A4[0] - 96, 52, 5, stroke=1, fill=1)
        pdf.setFillColor(color)
        pdf.circle(67, y - 16, 4, stroke=0, fill=1)
        pdf.setFillColor(MUTED)
        pdf.setFont("Helvetica-Bold", 7.5)
        pdf.drawString(82, y - 12, f"{index:02d}  {label.upper()}")
        pdf.setFillColor(INK)
        pdf.setFont("Helvetica", 10.5)
        pdf.drawString(82, y - 29, value)
        y -= 68
    footer(pdf, 2)
    pdf.save()


def appendix(path: Path) -> None:
    pdf = canvas.Canvas(str(path), pagesize=A4)
    pdf.setTitle("Research Appendix")
    pdf.setAuthor("Transall synthetic review sample")
    setup_page(pdf, "Appendix: Sample Data", "01 / APPENDIX")

    columns = [48, 150, 286, 424, A4[0] - 48]
    headers = ["ITEM", "SOURCE", "PAGES", "STATUS"]
    values = [
        ["A-01", "Research note", "2", "Ready"],
        ["A-02", "Image-only scan", "1", "OCR"],
        ["A-03", "Translation sample", "1", "Review"],
        ["A-04", "Output artifact", "-", "Generated"],
    ]
    top = 670
    row_height = 44
    pdf.setFillColor(SOURCE)
    pdf.rect(columns[0], top, columns[-1] - columns[0], row_height, stroke=0, fill=1)
    pdf.setFillColor(PAPER)
    pdf.setFont("Helvetica-Bold", 8)
    for index, header in enumerate(headers):
        pdf.drawString(columns[index] + 9, top + 17, header)
    pdf.setFont("Helvetica", 9.5)
    for row_index, row in enumerate(values, start=1):
        y = top - row_index * row_height
        pdf.setFillColor(HexColor("#FBFAF6") if row_index % 2 else HexColor("#F0F2EC"))
        pdf.rect(columns[0], y, columns[-1] - columns[0], row_height, stroke=0, fill=1)
        pdf.setFillColor(INK_SOFT)
        for index, value in enumerate(row):
            pdf.drawString(columns[index] + 9, y + 17, value)
    pdf.setStrokeColor(LINE)
    pdf.rect(columns[0], top - len(values) * row_height, columns[-1] - columns[0], row_height * (len(values) + 1), stroke=1, fill=0)

    draw_section(
        pdf,
        "Note",
        "This appendix exists only to test merge order and preview rendering.",
        [
            "All names, identifiers, and values are invented for the Transall review package.",
            "The document can be distributed to App Review without exposing user information.",
        ],
        390,
    )
    footer(pdf, 1)
    pdf.save()


def translation_sample(path: Path) -> None:
    pdf = canvas.Canvas(str(path), pagesize=A4)
    pdf.setTitle("Translation Sample")
    pdf.setAuthor("Transall synthetic review sample")
    setup_page(pdf, "Translation Sample", "01 / TRANSLATE")
    draw_section(
        pdf,
        "Source text",
        "A short note about local document tools",
        [
            "A useful document tool should make routine work predictable.",
            "It should preserve the original file, explain when network access is required,",
            "and provide a clear result that the user can save or remove.",
            "This synthetic paragraph contains no personal or confidential information.",
        ],
        690,
    )
    draw_section(
        pdf,
        "Review instruction",
        "Translate this page from English to Simplified Chinese",
        [
            "Use a temporary, rate-limited review key entered only in Transall Settings.",
            "Confirm that the disclosure is visible before the task starts.",
        ],
        480,
    )
    footer(pdf, 1)
    pdf.save()


def scanned_page(path: Path) -> None:
    TEMP_DIR.mkdir(parents=True, exist_ok=True)
    image_path = TEMP_DIR / "transall-scanned-page.png"
    width, height = 1600, 2263
    image = Image.new("RGB", (width, height), "#eeeae0")
    draw = ImageDraw.Draw(image)
    title_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 66)
    heading_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 34)
    body_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 27)
    small_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 20)

    for y in range(0, height, 70):
        draw.line((0, y, width, y), fill="#e2ded4", width=1)
    draw.text((130, 135), "FIELD NOTE 07", font=title_font, fill="#26352d")
    draw.line((130, 245, width - 130, 245), fill="#8e958e", width=3)
    draw.text((130, 310), "LOCAL OCR OBSERVATION", font=heading_font, fill="#9a4939")
    lines = [
        "The document was captured as an image-only page.",
        "There is no embedded text layer in this PDF.",
        "Apple Vision should recognize each line on the Mac.",
        "The resulting PDF should remain readable and searchable.",
        "No real person, project, address, or account is referenced.",
    ]
    y = 410
    for line in lines:
        draw.text((130, y), line, font=body_font, fill="#3f4541")
        y += 70
    draw.rectangle((130, 850, width - 130, 1300), outline="#a9aea7", width=3)
    draw.text((175, 905), "CHECK", font=heading_font, fill="#356f52")
    checks = [
        "[1] Output contains recognized text",
        "[2] Preview appears in the result panel",
        "[3] Original scan remains unchanged",
        "[4] Task data can be removed locally",
    ]
    y = 1000
    for line in checks:
        draw.text((175, y), line, font=body_font, fill="#3f4541")
        y += 64
    draw.text(
        (130, height - 150),
        "SYNTHETIC TRANSALL REVIEW SAMPLE - SAFE FOR SCREENSHOTS",
        font=small_font,
        fill="#6a726c",
    )
    image.save(image_path, format="PNG", optimize=True)

    pdf = canvas.Canvas(str(path), pagesize=A4)
    pdf.setTitle("Image-only OCR Sample")
    pdf.setAuthor("Transall synthetic review sample")
    pdf.drawImage(ImageReader(str(image_path)), 0, 0, width=A4[0], height=A4[1])
    pdf.showPage()
    pdf.save()
    image_path.unlink(missing_ok=True)


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    research_notes(OUTPUT_DIR / "research-notes.pdf")
    appendix(OUTPUT_DIR / "appendix.pdf")
    translation_sample(OUTPUT_DIR / "translation-sample.pdf")
    scanned_page(OUTPUT_DIR / "scanned-page.pdf")
    print(OUTPUT_DIR)


if __name__ == "__main__":
    main()
