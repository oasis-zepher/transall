from __future__ import annotations

from typing import Any


DEPENDENCY_DEFINITIONS: dict[str, dict[str, Any]] = {
    "pymupdf": {
        "label": "PyMuPDF",
        "availability": {"type": "python", "name": "fitz"},
        "category": "core",
        "risk": "license_sensitive",
        "required_for": ["PDF edits", "PDF preview", "PDF translation fallback", "PDF OCR rendering"],
        "detail": "PDF operations use the installed PyMuPDF package. transall does not vendor PyMuPDF source.",
        "install_hint": "python -m pip install -r requirements.txt",
        "license_note": "PyMuPDF is dual licensed under AGPL-3.0 or a commercial Artifex license.",
    },
    "pillow": {
        "label": "Pillow",
        "availability": {"type": "python", "name": "PIL"},
        "category": "core",
        "risk": "low",
        "required_for": ["Image to PDF", "OCR image preparation"],
        "detail": "Image handling uses the installed Pillow package.",
        "install_hint": "python -m pip install -r requirements.txt",
    },
    "libreoffice": {
        "label": "LibreOffice",
        "availability": {"type": "command", "name": "soffice"},
        "category": "external_tool",
        "risk": "heavy",
        "required_for": ["Convert Office files to PDF"],
        "detail": "Office documents are converted through the local `soffice` command.",
        "install_hint": "brew install libreoffice 或 brew install --cask libreoffice",
    },
    "playwright": {
        "label": "Playwright Chromium",
        "availability": {"type": "python", "name": "playwright"},
        "category": "external_tool",
        "risk": "heavy",
        "required_for": ["Convert Markdown, HTML, and data files to PDF"],
        "detail": "transall owns the document renderer and uses installed Playwright Chromium only for PDF printing.",
        "install_hint": "python -m pip install -r requirements.txt && python -m playwright install chromium",
    },
    "markitdown": {
        "label": "MarkItDown",
        "availability": {"type": "python", "name": "markitdown"},
        "category": "optional",
        "risk": "heavy",
        "required_for": ["Extract Markdown from documents"],
        "detail": "Structured Markdown extraction uses the installed MarkItDown package with plugins enabled.",
        "install_hint": "python -m pip install -r requirements-optional.txt",
    },
    "tesseract": {
        "label": "Tesseract",
        "availability": {"type": "command", "name": "tesseract"},
        "category": "external_tool",
        "risk": "heavy",
        "required_for": ["OCR", "OCR fallback for PDF/Image to Markdown"],
        "detail": "OCR uses the local Tesseract command through pytesseract. transall does not vendor OCR engine source.",
        "install_hint": "brew install tesseract tesseract-lang && python -m pip install -r requirements.txt",
    },
    "babeldoc": {
        "label": "BabelDOC",
        "availability": {"type": "command", "name": "babeldoc"},
        "category": "optional",
        "risk": "heavy",
        "required_for": ["Layout-preserving PDF translation"],
        "detail": "Optional primary layout-preserving translation engine called as a local CLI.",
        "install_hint": "python -m pip install -r requirements-optional.txt",
        "license_note": "BabelDOC is not vendored; install and license it separately.",
    },
    "pdf2zh": {
        "label": "pdf2zh",
        "availability": {"type": "command", "name": "pdf2zh"},
        "category": "optional",
        "risk": "license_sensitive",
        "required_for": ["PDF translation fallback"],
        "detail": "Optional secondary layout-preserving translation engine called as a local CLI.",
        "install_hint": "python -m pip install -r requirements-optional.txt",
        "license_note": "pdf2zh is AGPLv3 and is not vendored by transall.",
    },
    "deepseek": {
        "label": "DeepSeek",
        "availability": {"type": "provider", "name": "deepseek"},
        "category": "optional",
        "risk": "low",
        "required_for": ["PDF translation"],
        "detail": "OpenAI-compatible translation provider.",
        "install_hint": "export DEEPSEEK_API_KEY=...",
    },
    "openai": {
        "label": "OpenAI",
        "availability": {"type": "provider", "name": "openai"},
        "category": "optional",
        "risk": "low",
        "required_for": ["PDF translation"],
        "detail": "OpenAI-compatible translation provider.",
        "install_hint": "export OPENAI_API_KEY=...",
    },
}


ENGINE_DEFINITIONS: dict[str, dict[str, Any]] = {
    "libreoffice_pdf": {
        "label": "LibreOffice PDF adapter",
        "dependencies": ["libreoffice"],
        "license_note": "LibreOffice is called through the local soffice command; source is not vendored.",
    },
    "transall_browser_pdf": {
        "label": "transall browser PDF renderer",
        "dependencies": ["playwright"],
        "license_note": "The document HTML renderer is transall code; Chromium is an installed external runtime.",
    },
    "transall_image_pdf": {
        "label": "transall image PDF renderer",
        "dependencies": ["pillow"],
        "license_note": "Image-to-PDF glue is transall code over the installed Pillow package.",
    },
    "markitdown": {
        "label": "MarkItDown adapter",
        "dependencies": ["markitdown"],
        "license_note": "MarkItDown is an optional installed package; source is not vendored.",
    },
    "tesseract_ocr": {
        "label": "Tesseract OCR adapter",
        "dependencies": ["tesseract", "pymupdf"],
        "license_note": "Tesseract is called as a local OCR engine; source is not vendored.",
    },
    "pymupdf_pdf_edit": {
        "label": "PyMuPDF PDF editor",
        "dependencies": ["pymupdf"],
        "license_note": "PyMuPDF is installed as a package and is not copied into transall.",
    },
    "babeldoc": {
        "label": "BabelDOC layout translator",
        "dependencies": ["babeldoc"],
        "license_note": "BabelDOC is optional and not vendored.",
    },
    "pdf2zh": {
        "label": "pdf2zh layout translator",
        "dependencies": ["pdf2zh"],
        "license_note": "pdf2zh is AGPLv3 and is not vendored.",
    },
    "builtin_pdf_translate": {
        "label": "transall PDF translation fallback",
        "dependencies": ["pymupdf"],
        "license_note": "Fallback PDF reconstruction is transall code over installed PyMuPDF.",
    },
}


def dependency_profile(names: list[str]) -> list[dict[str, str]]:
    profile: list[dict[str, str]] = []
    for name in names:
        dependency = DEPENDENCY_DEFINITIONS.get(name)
        if not dependency:
            continue
        profile.append(
            {
                "name": name,
                "label": str(dependency["label"]),
                "category": str(dependency["category"]),
                "risk": str(dependency["risk"]),
            }
        )
    return profile


def route_engine_payload(engine: str, fallback_engines: list[str] | None = None) -> dict[str, Any]:
    fallbacks = fallback_engines or []
    dependency_names: list[str] = []
    license_notes: list[str] = []
    for engine_name in [engine, *fallbacks]:
        engine_definition = ENGINE_DEFINITIONS.get(engine_name, {})
        for dependency_name in engine_definition.get("dependencies", []):
            if dependency_name not in dependency_names:
                dependency_names.append(dependency_name)
        note = engine_definition.get("license_note")
        if note and note not in license_notes:
            license_notes.append(str(note))
    return {
        "engine": engine,
        "fallbackEngines": fallbacks,
        "dependencyProfile": dependency_profile(dependency_names),
        "licenseNote": " ".join(license_notes),
    }
