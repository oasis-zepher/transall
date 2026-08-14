from __future__ import annotations

import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

import fitz

from .errors import ProviderNotConfigured
from .pdf_ops import parse_page_spec
from .translation_engines import translate_with_layout_engines


@dataclass
class TranslationProvider:
    name: str
    base_url: str
    api_key: str
    model: str


def load_provider_configs(include_secrets: bool = False) -> list[dict[str, Any]]:
    defaults = {
        "openai": {
            "base_url": os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1"),
            "api_key": os.environ.get("OPENAI_API_KEY", ""),
            "model": os.environ.get("OPENAI_MODEL", "gpt-4o-mini"),
        },
        "deepseek": {
            "base_url": os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com/v1"),
            "api_key": os.environ.get("DEEPSEEK_API_KEY", ""),
            "model": os.environ.get("DEEPSEEK_MODEL", "deepseek-chat"),
        },
    }
    providers: list[dict[str, Any]] = []
    for name, config in defaults.items():
        data: dict[str, Any] = {
            "name": name,
            "base_url": config["base_url"],
            "model": config["model"],
            "configured": bool(config["api_key"]),
        }
        if include_secrets:
            data["api_key"] = config["api_key"]
        providers.append(data)
    return providers


def get_provider(name: str) -> TranslationProvider:
    for config in load_provider_configs(include_secrets=True):
        if config["name"] == name:
            if not config["api_key"]:
                raise ProviderNotConfigured(f"{name} API key is not configured")
            return TranslationProvider(
                name=name,
                base_url=config["base_url"].rstrip("/"),
                api_key=config["api_key"],
                model=config["model"],
            )
    raise ProviderNotConfigured(f"Unknown translation provider: {name}")


def translate_text(provider: TranslationProvider, text: str, source_lang: str, target_lang: str, glossary: str = "") -> str:
    import httpx

    if not text.strip():
        return text
    system = (
        "Translate the user's document text. Preserve numbers, formulas, citations, and line breaks when possible. "
        "Return only translated text."
    )
    if glossary:
        system += f"\nGlossary:\n{glossary}"
    payload = {
        "model": provider.model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": f"Source language: {source_lang}\nTarget language: {target_lang}\n\n{text}"},
        ],
        "temperature": 0.1,
        "max_tokens": 8192,
    }
    headers = {"Authorization": f"Bearer {provider.api_key}", "Content-Type": "application/json"}
    last_error: Exception | None = None
    with httpx.Client(timeout=60) as client:
        for attempt in range(3):
            try:
                response = client.post(f"{provider.base_url}/chat/completions", json=payload, headers=headers)
                response.raise_for_status()
                data = response.json()
                return data["choices"][0]["message"]["content"].strip()
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code != 429 and exc.response.status_code < 500:
                    raise
                last_error = exc
            except (httpx.TimeoutException, httpx.TransportError) as exc:
                last_error = exc
            if attempt < 2:
                time.sleep(2**attempt)
    raise last_error  # type: ignore[misc]


def translate_pdf(
    source: Path,
    output: Path,
    provider_name: str,
    source_lang: str,
    target_lang: str,
    pages_spec: str = "",
    output_mode: str = "translated",
    glossary: str = "",
    on_layout_fallback: Callable[[str], None] | None = None,
    on_progress: Callable[[int, int], None] | None = None,
) -> Path:
    provider = get_provider(provider_name)
    try:
        return translate_with_layout_engines(
            source=source,
            output=output,
            provider=provider,
            source_lang=source_lang,
            target_lang=target_lang,
            pages_spec=pages_spec,
            output_mode=output_mode,
            glossary=glossary,
        )
    except Exception as exc:
        if on_layout_fallback is not None:
            on_layout_fallback(str(exc))

    original = fitz.open(source)
    translated = fitz.open()
    failed_pages: list[int] = []
    selected_pages = set(parse_page_spec(pages_spec, original.page_count))
    page_texts: dict[int, str] = {
        index: page.get_text("text").strip()
        for index, page in enumerate(original, start=1)
        if index in selected_pages
    }
    results: dict[int, str] = {}
    if page_texts:
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = {
                pool.submit(_translate_page, provider, text, source_lang, target_lang, glossary, index): index
                for index, text in page_texts.items()
            }
            for future in as_completed(futures):
                index = futures[future]
                translated_text, failed = future.result()
                results[index] = translated_text
                if failed:
                    failed_pages.append(index)
                if on_progress is not None:
                    on_progress(len(results), len(page_texts))
    try:
        for index, page in enumerate(original, start=1):
            if index not in selected_pages:
                translated.insert_pdf(original, from_page=index - 1, to_page=index - 1)
                continue
            new_page = translated.new_page(width=page.rect.width, height=page.rect.height)
            if index not in results:
                failed_pages.append(index)
                new_page.insert_text((72, 72), f"[No extractable text on page {index}]", fontsize=12)
                continue
            font_name = _insert_cjk_font(new_page)
            new_page.insert_textbox(
                page.rect + (48, 48, -48, -48),
                results[index],
                fontsize=10,
                color=(0, 0, 0),
                fontname=font_name,
            )
            if output_mode == "bilingual":
                translated.insert_pdf(original, from_page=index - 1, to_page=index - 1)
        if failed_pages and len(failed_pages) == len(selected_pages):
            raise RuntimeError(f"All selected pages failed translation: {failed_pages}")
        translated.save(output, garbage=4, deflate=True)
        return output
    finally:
        original.close()
        translated.close()


def _translate_page(
    provider: TranslationProvider,
    text: str,
    source_lang: str,
    target_lang: str,
    glossary: str,
    page_number: int,
) -> tuple[str, bool]:
    try:
        return translate_text(provider, text, source_lang, target_lang, glossary), False
    except Exception as exc:
        return f"[Translation failed on page {page_number}: {exc}]", True


def _insert_cjk_font(page: fitz.Page) -> str:
    try:
        page.insert_font(fontname="china-ss")
        return "china-ss"
    except Exception:
        pass
    for font_file in (
        Path("/System/Library/Fonts/STHeiti Medium.ttc"),
        Path("/System/Library/Fonts/PingFang.ttc"),
        Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
    ):
        if not font_file.exists():
            continue
        try:
            page.insert_font(fontname="docwork-cjk", fontfile=str(font_file))
            return "docwork-cjk"
        except Exception:
            continue
    return "helv"
