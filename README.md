# Doc Workbench

macOS local web service for document conversion, PDF edits, Markdown extraction, PDF translation, and OCR.

## Start

```bash
python -m pip install -r requirements.txt
python -m playwright install chromium
python -m uvicorn app.main:app --host 127.0.0.1 --port 8765
```

Open:

```text
http://127.0.0.1:8765
```

## Translation Providers

Set one or both providers before starting the server:

```bash
export DEEPSEEK_API_KEY="..."
export DEEPSEEK_MODEL="deepseek-chat"
export DEEPSEEK_BASE_URL="https://api.deepseek.com/v1"

export OPENAI_API_KEY="..."
export OPENAI_MODEL="gpt-4o-mini"
export OPENAI_BASE_URL="https://api.openai.com/v1"
```

Provider API keys are never returned by `/api/config/providers`.

## Scope

- Convert to PDF: Office via LibreOffice, Markdown/HTML/text/data via full Playwright Chromium print layout, images via Pillow.
- Extract Markdown: MarkItDown with plugins enabled for common document, data, archive, and media-adjacent inputs.
- PDF edits: merge, delete pages, reorder, rotate, crop, watermark, text find/replace.
- PDF translation: BabelDOC first for layout-preserving translation, then pdf2zh, then fallback OpenAI-compatible DeepSeek/OpenAI reconstruction. Outputs translated or bilingual PDF.
- OCR: local Tesseract for PDF and image inputs, with searchable PDF or plain text output.
- Files are stored under `work/docwork-data` and cleaned by the app TTL policy.

## Required Local Tools

```bash
brew install libreoffice qpdf tesseract tesseract-lang ffmpeg
python -m pip install -r requirements.txt
python -m playwright install chromium
```

`pdf2zh==1.7.9` is pinned because newer pdf2zh releases currently require Python `<3.13`; this project is running on Python 3.13.

Layout translation engine order:

```text
BabelDOC CLI -> pdf2zh CLI -> built-in fallback translator
```

BabelDOC uses OpenAI-compatible settings from the selected provider and is preferred because it is closer to pdf2zh/BabelDOC style layout reconstruction than the fallback text-only PDF builder.
