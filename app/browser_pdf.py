from __future__ import annotations

import csv
import html
import json
import threading
from pathlib import Path
from xml.dom import minidom

from .config import HTML_EXTENSIONS, MARKDOWN_EXTENSIONS


_BROWSER_SLOTS = threading.BoundedSemaphore(2)


def render_browser_pdf(source: Path, output: Path) -> Path:
    try:
        from playwright.sync_api import sync_playwright
    except Exception as exc:
        raise RuntimeError("Playwright is not installed. Run: pip install -r requirements.txt && python -m playwright install chromium") from exc

    if not _BROWSER_SLOTS.acquire(timeout=120):
        raise RuntimeError("Browser PDF queue timed out after 2 minutes")
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        with sync_playwright() as playwright:
            try:
                browser = playwright.chromium.launch()
            except Exception as exc:
                raise RuntimeError("Playwright Chromium is not installed. Run: python -m playwright install chromium") from exc
            try:
                context = browser.new_context(java_script_enabled=False, service_workers="block")
                page = context.new_page()
                page.route("**/*", lambda route: route.abort())
                page.set_content(document_html(source), wait_until="domcontentloaded", timeout=30_000)
                page.pdf(
                    path=str(output),
                    format="A4",
                    print_background=True,
                    prefer_css_page_size=True,
                    margin={"top": "16mm", "right": "14mm", "bottom": "16mm", "left": "14mm"},
                )
            finally:
                browser.close()
    finally:
        _BROWSER_SLOTS.release()
    return output


def document_html(source: Path) -> str:
    ext = source.suffix.lower()
    text = source.read_text(encoding="utf-8", errors="replace")
    if ext in HTML_EXTENSIONS:
        body = _html_body(text)
    elif ext in MARKDOWN_EXTENSIONS:
        body = _markdown_to_html(text)
    elif ext in {".csv", ".tsv"}:
        body = _delimited_to_table(text, delimiter="\t" if ext == ".tsv" else ",")
    elif ext == ".json":
        body = _formatted_code(_pretty_json(text), "json")
    elif ext == ".xml":
        body = _formatted_code(_pretty_xml(text), "xml")
    elif ext in {".yaml", ".yml"}:
        body = _formatted_code(text, "yaml")
    else:
        body = _formatted_code(text, "text")
    return _page_shell(source.name, body)


def _page_shell(title: str, body: str) -> str:
    return f"""<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>{html.escape(title)}</title>
    <style>
      @page {{
        size: A4;
        margin: 16mm 14mm;
      }}
      :root {{
        color: #202522;
        background: #fbfcf9;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", sans-serif;
      }}
      body {{
        margin: 0;
        font-size: 13px;
        line-height: 1.58;
      }}
      h1, h2, h3 {{
        break-after: avoid;
        line-height: 1.18;
        margin: 1.1em 0 0.45em;
      }}
      h1 {{ font-size: 28px; }}
      h2 {{ font-size: 21px; }}
      h3 {{ font-size: 16px; }}
      p, ul, ol, pre, table, blockquote {{ margin: 0 0 0.82em; }}
      blockquote {{
        border-left: 3px solid #b3482d;
        color: #48534b;
        padding-left: 12px;
      }}
      pre, code {{
        font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      }}
      pre {{
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        border: 1px solid #cbd6cc;
        background: #f4f6f3;
        padding: 12px;
      }}
      table {{
        border-collapse: collapse;
        width: 100%;
        break-inside: auto;
      }}
      tr {{ break-inside: avoid; }}
      th, td {{
        border: 1px solid #cbd6cc;
        padding: 6px 8px;
        vertical-align: top;
        overflow-wrap: anywhere;
      }}
      th {{
        background: #eef3ee;
        text-align: left;
      }}
      img {{
        max-width: 100%;
      }}
      .doc-meta {{
        color: #667166;
        font-size: 11px;
        letter-spacing: 0.08em;
        text-transform: uppercase;
        margin-bottom: 12px;
      }}
    </style>
  </head>
  <body>
    <div class="doc-meta">{html.escape(title)}</div>
    {body}
  </body>
</html>"""


def _html_body(text: str) -> str:
    lower = text.lower()
    if "<body" not in lower:
        return text
    start = lower.find("<body")
    start = text.find(">", start) + 1
    end = lower.rfind("</body>")
    return text[start:end] if start > 0 and end > start else text


def _markdown_to_html(text: str) -> str:
    try:
        import markdown
    except Exception:
        return _formatted_code(text, "markdown")
    return markdown.markdown(
        text,
        extensions=["extra", "sane_lists", "tables", "fenced_code", "toc"],
        output_format="html5",
    )


def _delimited_to_table(text: str, delimiter: str) -> str:
    rows = list(csv.reader(text.splitlines(), delimiter=delimiter))
    if not rows:
        return "<table></table>"
    head, *body = rows
    header = "".join(f"<th>{html.escape(cell)}</th>" for cell in head)
    body_rows = []
    for row in body:
        cells = "".join(f"<td>{html.escape(cell)}</td>" for cell in row)
        body_rows.append(f"<tr>{cells}</tr>")
    return f"<table><thead><tr>{header}</tr></thead><tbody>{''.join(body_rows)}</tbody></table>"


def _pretty_json(text: str) -> str:
    try:
        return json.dumps(json.loads(text), ensure_ascii=False, indent=2)
    except Exception:
        return text


def _pretty_xml(text: str) -> str:
    try:
        return minidom.parseString(text.encode("utf-8")).toprettyxml(indent="  ")
    except Exception:
        return text


def _formatted_code(text: str, kind: str) -> str:
    return f'<pre data-kind="{html.escape(kind)}">{html.escape(text)}</pre>'
