from __future__ import annotations

import importlib.util
import shutil
from typing import Any

from .translation import load_provider_configs


def command_available(command: str) -> bool:
    return shutil.which(command) is not None


def python_module_available(module: str) -> bool:
    return importlib.util.find_spec(module) is not None


def collect_diagnostics() -> dict[str, list[dict[str, Any]]]:
    providers = {provider["name"]: provider for provider in load_provider_configs(include_secrets=False)}
    dependencies = [
        {
            "name": "libreoffice",
            "label": "LibreOffice",
            "available": command_available("soffice"),
            "required_for": ["Convert Office files to PDF"],
            "detail": "Office documents are converted through the `soffice` command.",
            "install_hint": "brew install libreoffice 或 brew install --cask libreoffice",
        },
        {
            "name": "playwright",
            "label": "Playwright Chromium",
            "available": python_module_available("playwright"),
            "required_for": ["Convert Markdown, HTML, and data files to PDF"],
            "detail": "Browser-rendered PDFs need the Playwright Python package and installed Chromium browser.",
            "install_hint": "python -m pip install -r requirements.txt && python -m playwright install chromium",
        },
        {
            "name": "markitdown",
            "label": "MarkItDown",
            "available": python_module_available("markitdown"),
            "required_for": ["Extract Markdown from documents"],
            "detail": "Structured Markdown extraction uses MarkItDown with plugins enabled.",
            "install_hint": "python -m pip install -r requirements.txt",
        },
        {
            "name": "tesseract",
            "label": "Tesseract",
            "available": command_available("tesseract"),
            "required_for": ["OCR", "OCR fallback for PDF/Image to Markdown"],
            "detail": "OCR uses the local Tesseract command through pytesseract.",
            "install_hint": "brew install tesseract tesseract-lang && python -m pip install -r requirements.txt",
        },
        {
            "name": "babeldoc",
            "label": "BabelDOC",
            "available": command_available("babeldoc"),
            "required_for": ["Layout-preserving PDF translation"],
            "detail": "Preferred layout-preserving translation engine.",
            "install_hint": "python -m pip install -r requirements.txt",
        },
        {
            "name": "pdf2zh",
            "label": "pdf2zh",
            "available": command_available("pdf2zh"),
            "required_for": ["PDF translation fallback"],
            "detail": "Secondary layout-preserving translation engine when BabelDOC is unavailable.",
            "install_hint": "python -m pip install -r requirements.txt",
        },
        {
            "name": "deepseek",
            "label": "DeepSeek",
            "available": bool(providers.get("deepseek", {}).get("configured")),
            "required_for": ["PDF translation"],
            "detail": "OpenAI-compatible translation provider.",
            "install_hint": "export DEEPSEEK_API_KEY=...",
        },
        {
            "name": "openai",
            "label": "OpenAI",
            "available": bool(providers.get("openai", {}).get("configured")),
            "required_for": ["PDF translation"],
            "detail": "OpenAI-compatible translation provider.",
            "install_hint": "export OPENAI_API_KEY=...",
        },
    ]
    return {"dependencies": dependencies}
