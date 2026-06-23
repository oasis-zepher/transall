from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Protocol

import fitz


class ProviderLike(Protocol):
    name: str
    base_url: str
    api_key: str
    model: str


def babeldoc_available() -> bool:
    return shutil.which("babeldoc") is not None


def pdf2zh_available() -> bool:
    return shutil.which("pdf2zh") is not None


def translate_with_layout_engines(
    source: Path,
    output: Path,
    provider: ProviderLike,
    source_lang: str,
    target_lang: str,
    pages_spec: str = "",
    output_mode: str = "translated",
    glossary: str = "",
) -> Path:
    errors: list[str] = []
    if babeldoc_available():
        try:
            return translate_with_babeldoc(
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
            errors.append(f"BabelDOC: {exc}")

    if pdf2zh_available() and not glossary.strip():
        try:
            return translate_with_pdf2zh(
                source=source,
                output=output,
                provider=provider,
                source_lang=source_lang,
                target_lang=target_lang,
                pages_spec=pages_spec,
                output_mode=output_mode,
            )
        except Exception as exc:
            errors.append(f"pdf2zh: {exc}")

    raise RuntimeError("; ".join(errors) or "No layout-preserving translation engine is available")


def translate_with_babeldoc(
    source: Path,
    output: Path,
    provider: ProviderLike,
    source_lang: str,
    target_lang: str,
    pages_spec: str = "",
    output_mode: str = "translated",
    glossary: str = "",
) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "babeldoc",
        "--files",
        str(source.resolve()),
        "--output",
        str(output.parent.resolve()),
        "--openai",
        "--openai-model",
        provider.model,
        "--openai-base-url",
        provider.base_url,
        "--openai-api-key",
        provider.api_key,
        "--lang-in",
        source_lang or "en",
        "--lang-out",
        target_lang or "zh",
        "--qps",
        "2",
        "--watermark-output-mode",
        "no_watermark",
    ]
    if output_mode == "bilingual":
        command.append("--no-mono")
    else:
        command.append("--no-dual")
    if pages_spec:
        command.extend(["--pages", pages_spec])

    glossary_path: Path | None = None
    if glossary.strip():
        glossary_path = _write_glossary_csv(glossary)
        command.extend(["--glossary-files", str(glossary_path)])

    try:
        subprocess.run(command, check=True, capture_output=True, text=True, timeout=1800)
    finally:
        if glossary_path:
            glossary_path.unlink(missing_ok=True)

    generated = _find_babeldoc_output(output.parent, source.stem, output_mode)
    if generated is None:
        raise RuntimeError("BabelDOC did not produce the expected PDF output")
    if generated != output:
        shutil.copy2(generated, output)
    if output_mode != "bilingual" and _normalized_pdf_text(source) == _normalized_pdf_text(output):
        raise RuntimeError("BabelDOC output text is unchanged")
    return output


def translate_with_pdf2zh(
    source: Path,
    output: Path,
    provider: ProviderLike,
    source_lang: str,
    target_lang: str,
    pages_spec: str = "",
    output_mode: str = "translated",
) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    env = {
        **__import__("os").environ.copy(),
        "OPENAI_API_KEY": provider.api_key,
        "OPENAI_BASE_URL": provider.base_url,
    }
    command = [
        "pdf2zh",
        str(source.resolve()),
        "--service",
        f"openai:{provider.model}",
        "--lang-in",
        source_lang or "en",
        "--lang-out",
        target_lang or "zh",
        "--thread",
        "4",
    ]
    if pages_spec:
        command.extend(["--pages", pages_spec])

    subprocess.run(command, cwd=output.parent, env=env, check=True, capture_output=True, text=True, timeout=1800)
    generated = output.parent / f"{source.stem}-{'dual' if output_mode == 'bilingual' else 'zh'}.pdf"
    if not generated.exists():
        raise RuntimeError("pdf2zh did not produce the expected PDF output")
    if generated != output:
        shutil.copy2(generated, output)
    if output_mode != "bilingual" and _normalized_pdf_text(source) == _normalized_pdf_text(output):
        raise RuntimeError("pdf2zh output text is unchanged")
    return output


def _find_babeldoc_output(output_dir: Path, source_stem: str, output_mode: str) -> Path | None:
    candidates = sorted(output_dir.glob(f"{source_stem}*.pdf"), key=lambda path: path.stat().st_mtime, reverse=True)
    if output_mode == "bilingual":
        preferred_tokens = ("dual", "bilingual")
    else:
        preferred_tokens = ("mono", "translated", "zh")
    for token in preferred_tokens:
        for candidate in candidates:
            if token in candidate.stem.lower():
                return candidate
    return candidates[0] if candidates else None


def _write_glossary_csv(glossary: str) -> Path:
    handle = tempfile.NamedTemporaryFile("w", suffix=".csv", encoding="utf-8", delete=False)
    path = Path(handle.name)
    with handle:
        handle.write("source,target\n")
        for line in glossary.splitlines():
            cleaned = line.strip()
            if not cleaned:
                continue
            if "," in cleaned:
                source, target = cleaned.split(",", 1)
            elif "=>" in cleaned:
                source, target = cleaned.split("=>", 1)
            elif "=" in cleaned:
                source, target = cleaned.split("=", 1)
            else:
                source, target = cleaned, cleaned
            handle.write(f"{source.strip()},{target.strip()}\n")
    return path


def _normalized_pdf_text(path: Path) -> str:
    try:
        doc = fitz.open(path)
        text = "\n".join(page.get_text("text") for page in doc)
        doc.close()
    except Exception:
        return ""
    return " ".join(text.split())
