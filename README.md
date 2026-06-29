# transall

macOS local web service for document conversion, PDF edits, Markdown extraction, PDF translation, and OCR.

## Start

```bash
python -m pip install -r requirements.txt
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

## Install By Feature

Base web service, image PDF conversion, PDF edits, preview, and built-in PDF translation fallback:

```bash
python -m pip install -r requirements.txt
```

Markdown/HTML/Data to PDF uses transall's own HTML renderer and installed Playwright Chromium for PDF printing:

```bash
python -m playwright install chromium
```

Office to PDF uses the local LibreOffice command:

```bash
brew install libreoffice
# or
brew install --cask libreoffice
```

OCR and OCR fallback for PDF/Image to Markdown use local Tesseract:

```bash
brew install tesseract tesseract-lang
```

Enhanced Markdown extraction and layout-preserving PDF translation are optional:

```bash
python -m pip install -r requirements-optional.txt
```

`pdf2zh==1.7.9` and `numpy<2.3` are kept in `requirements-optional.txt` because newer pdf2zh releases currently require Python `<3.13`; this project is running on Python 3.13.

Layout translation engine order:

```text
BabelDOC CLI -> pdf2zh CLI -> built-in fallback translator
```

BabelDOC uses OpenAI-compatible settings from the selected provider and is preferred because it is closer to pdf2zh/BabelDOC style layout reconstruction than the fallback text-only PDF builder.

## External Engine Policy

transall does not copy AGPL or large third-party engine source into this repository. It calls installed local tools or packages through adapters:

- LibreOffice, Tesseract, Playwright Chromium, BabelDOC, and pdf2zh remain external/local engines.
- PyMuPDF is installed as a Python package and is not vendored; it is dual licensed under AGPL-3.0 or a commercial Artifex license.
- pdf2zh is AGPLv3 and is only used as an optional local CLI fallback.
- MarkItDown and BabelDOC are optional installed packages, not copied source.
