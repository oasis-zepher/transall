# transall

Native macOS document workbench for PDF edits, Markdown extraction, PDF translation, OCR, and native PDF creation. The SwiftUI app uses PDFKit, Core Graphics, Vision, and URLSession; the separately runnable browser edition keeps the broader Python conversion engine.

## Native macOS App

Requirements: macOS 14+ and Xcode 26.6 or a compatible newer release toolchain. The native app does not require Python, `uv`, Homebrew, or external document tools.

```bash
cd native/TransallMac
swift run TransallMac
```

The native app runs inside App Sandbox. See [`native/TransallMac/README.md`](native/TransallMac/README.md) for build, test, and packaging details.

## Browser UI

```bash
python -m pip install -r requirements.txt
python -m uvicorn app.main:app --host 127.0.0.1 --port 8765
```

For a pinned, reproducible install use the lock file instead:

```bash
python -m pip install -r requirements.lock
```

Open:

```text
http://127.0.0.1:8765
```

At most 2 jobs run concurrently by default; override with `DOCWORK_MAX_JOBS`.

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
- PDF edits: merge (keeps upload order), delete pages, reorder, rotate, crop (x0,y0,x1,y1 in PDF points), watermark, text find/replace.
- PDF translation: BabelDOC for layout-preserving translation, with an OpenAI-compatible DeepSeek/OpenAI text reconstruction fallback. Outputs translated or bilingual PDF.
- OCR: OCRmyPDF for searchable PDF output when installed; Tesseract handles images, plain text output, and the compatibility fallback.
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

OCR uses one public workflow. OCRmyPDF improves searchable PDF output without adding another UI mode; Tesseract remains the image/text engine and fallback:

```bash
brew install ocrmypdf tesseract-lang
```

Enhanced Markdown extraction and layout-preserving PDF translation are optional:

```bash
python -m pip install -r requirements-optional.txt
```

Layout translation engine order:

```text
BabelDOC CLI -> built-in fallback translator
```

BabelDOC uses OpenAI-compatible settings from the selected provider and preserves layout more effectively than the fallback text-only PDF builder.

## External Engine Policy

transall does not copy AGPL or large third-party engine source into this repository. It calls installed local tools or packages through adapters:

- LibreOffice, OCRmyPDF, Tesseract, Playwright Chromium, and BabelDOC remain external/local engines.
- OCRmyPDF is MPL-2.0 and is called as an installed local command; its source is not copied into transall.
- PyMuPDF is installed as a Python package and is not vendored; it is dual licensed under AGPL-3.0 or a commercial Artifex license.
- MarkItDown and BabelDOC are optional installed packages, not copied source.
