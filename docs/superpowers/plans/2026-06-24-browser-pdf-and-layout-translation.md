# Browser PDF and Layout Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve browser PDF rendering for text/data inputs and route PDF translation through layout-preserving engines before fallback text reconstruction.

**Architecture:** Split browser PDF rendering into a focused module that converts Markdown, HTML, CSV/TSV, JSON, XML, YAML, and plain text into print-ready HTML for Playwright. Split PDF translation engine selection into BabelDOC CLI, pdf2zh CLI, and existing fallback reconstruction, preserving failure reasons for logs.

**Tech Stack:** Python FastAPI, PyMuPDF, Playwright Chromium, MarkItDown, BabelDOC CLI, pdf2zh CLI, DeepSeek/OpenAI-compatible chat completions, unittest.

---

### Task 1: Browser PDF Renderer

**Files:**
- Create: `app/browser_pdf.py`
- Modify: `app/conversion.py`
- Test: `tests/test_core.py`

- [ ] Add tests proving Markdown/HTML/CSV/JSON use `_render_browser_pdf`.
- [ ] Move Playwright rendering and print CSS into `app/browser_pdf.py`.
- [ ] Render CSV/TSV as real HTML tables and JSON/XML/YAML as formatted documents.
- [ ] Verify generated PDFs report Chromium as creator via `pdfinfo`.

### Task 2: Layout Translation Engines

**Files:**
- Create: `app/translation_engines.py`
- Modify: `app/translation.py`
- Test: `tests/test_core.py`

- [ ] Add tests proving engine order is BabelDOC, pdf2zh, fallback.
- [ ] Add `TranslationAttempt` metadata with engine name, success flag, output path, and error text.
- [ ] Call BabelDOC by CLI when installed and no glossary is set.
- [ ] Preserve current pdf2zh and fallback behavior as lower-priority engines.

### Task 3: Dependencies and Documentation

**Files:**
- Modify: `requirements.txt`
- Modify: `README.md`
- Test: `tests/test_core.py`

- [ ] Add BabelDOC dependency.
- [ ] Document CLI engine order and version constraints.
- [ ] Verify `python -m pip check`, unit tests, and a real one-page translation.
