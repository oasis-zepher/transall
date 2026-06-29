from __future__ import annotations

from pathlib import Path
from typing import Any

from .config import MAX_UPLOAD_BYTES
from .diagnostics import collect_diagnostics


FORMAT_DEFINITIONS: dict[str, dict[str, Any]] = {
    "pdf": {"label": "PDF", "input": ".pdf", "detail": "PDF 文档"},
    "word": {"label": "Word", "input": ".doc,.docx", "detail": "Word 文档"},
    "ppt": {"label": "PPT", "input": ".ppt,.pptx", "detail": "PowerPoint 幻灯片"},
    "excel": {"label": "Excel", "input": ".xls,.xlsx", "detail": "Excel 表格"},
    "md": {"label": "Markdown", "input": ".md,.markdown", "detail": "Markdown 文本"},
    "html": {"label": "HTML", "input": ".html,.htm", "detail": "HTML 页面"},
    "image": {"label": "Image", "input": ".png,.jpg,.jpeg,.webp,.tif,.tiff", "detail": "图片文件"},
    "data": {
        "label": "Data",
        "input": ".txt,.text,.csv,.json,.xml,.yaml,.yml,.zip,.epub",
        "pdf_input": ".txt,.text,.csv,.json,.xml,.yaml,.yml",
        "detail": "文本、表格、结构化数据或归档文件",
    },
    "translated_pdf": {"label": "中文PDF", "input": ".pdf", "detail": "翻译后的 PDF"},
    "ocr": {"label": "OCR", "input": ".pdf,.png,.jpg,.jpeg,.webp,.tif,.tiff", "detail": "OCR 结果"},
}

ROUTE_COPY: dict[str, dict[str, str]] = {
    "convert": {
        "kindLabel": "转 PDF",
        "output": "输出为 PDF，可下载并预览前 12 页。",
        "summary": "使用本地转换引擎生成 PDF。Office 走 LibreOffice，图片走本地合成，Markdown/HTML/文本数据走 Playwright 排版。",
    },
    "extract_markdown": {
        "kindLabel": "转 Markdown",
        "output": "输出为 Markdown，目标是结构化文本，不承诺版式保真。",
        "summary": "使用 MarkItDown 插件化抽取文档结构，适合知识库、摘要和后续文本处理。",
    },
    "pdf_edit": {
        "kindLabel": "PDF 修改",
        "output": "输出为新的 PDF，原文件不会被覆盖。",
        "summary": "支持合并、删除页、旋转、水印和文字查找替换。内容级编辑不是 Word 式自由编辑。",
    },
    "pdf_translate": {
        "kindLabel": "PDF 翻译",
        "output": "输出为纯译文 PDF 或双语对照 PDF。",
        "summary": "优先使用 BabelDOC 做版式保真翻译，失败后回退到 pdf2zh，再回退到基础文本重建。扫描件请先走 OCR。",
    },
    "ocr": {
        "kindLabel": "OCR",
        "output": "输出为可搜索 PDF 或纯文本。",
        "summary": "使用本机 Tesseract 识别 PDF 或图片中的文字。适合扫描件、截图和图片型 PDF。",
    },
}


def capabilities_payload() -> dict[str, Any]:
    return {
        "formats": FORMAT_DEFINITIONS,
        "routes": list(_supported_routes()),
    }


def resolve_route(source: str | None, target: str | None) -> dict[str, Any] | None:
    if not source or not target:
        return None
    for route in _supported_routes():
        if route["source"] == source and route["target"] == target:
            return route
    if source in FORMAT_DEFINITIONS and target in FORMAT_DEFINITIONS:
        return {
            "source": source,
            "target": target,
            "kind": "convert",
            "title": f"{_format_label(source)} → {_format_label(target)}",
            "enabled": False,
            "accept": FORMAT_DEFINITIONS[source].get("input", ""),
            "input": FORMAT_DEFINITIONS[source].get("detail", "未知格式"),
            "output": "该路径第一版未接入。",
            "summary": "当前支持：常见文档/图片/文本数据转 PDF，常见文档/数据转 Markdown，PDF 修改，PDF 翻译为中文PDF，PDF/图片 OCR。",
            "kindLabel": "未接入",
            "requirements": [],
            "optionPanels": [],
        }
    return None


def preflight(payload: dict[str, Any]) -> dict[str, Any]:
    source = str(payload.get("source_format") or "")
    target = str(payload.get("target_format") or "")
    kind = str(payload.get("kind") or "")
    files = payload.get("files") or []
    options = payload.get("options") or {}
    if not isinstance(files, list):
        files = []
    if not isinstance(options, dict):
        options = {}

    route = resolve_route(source, target)
    blocking: list[dict[str, Any]] = []
    warnings: list[dict[str, Any]] = []
    requirements = _requirements_for_route(route, options)

    if not route or not route.get("enabled") or route.get("kind") != kind:
        blocking.append(
            {
                "code": "route_unavailable",
                "message": "该转换路径当前未接入。",
                "hint": "请选择已支持的源格式和目标格式。",
            }
        )
    if not files:
        blocking.append({"code": "file_required", "message": "需要上传文件。", "hint": "请选择至少一个输入文件。"})

    total_size = sum(_file_size(file) for file in files)
    if total_size > MAX_UPLOAD_BYTES:
        blocking.append(
            {
                "code": "upload_too_large",
                "message": "上传文件超过 200 MB 限制。",
                "hint": "减少文件数量或压缩文件后重试。",
                "limit": MAX_UPLOAD_BYTES,
            }
        )

    accept = str(route.get("accept") or "") if route else ""
    bad_files = [file for file in files if not _file_allowed(str(file.get("name", "")), accept)]
    if bad_files:
        blocking.append(
            {
                "code": "unsupported_file_type",
                "message": "文件类型不符合当前路径。",
                "hint": f"当前路径接受：{accept}",
                "files": [file.get("name", "") for file in bad_files],
            }
        )

    diagnostics = {item["name"]: item for item in collect_diagnostics().get("dependencies", [])}
    groups: dict[str, list[dict[str, Any]]] = {}
    for requirement in requirements:
        required = requirement.get("required")
        name = str(requirement.get("name", ""))
        dependency = diagnostics.get(name, {})
        available = bool(dependency.get("available"))
        if required == "one-of-markdown":
            groups.setdefault(required, []).append(requirement | {"available": available, "dependency": dependency})
            continue
        if required is True and not available:
            blocking.append(_missing_issue(name, dependency))
        if required is False and not available:
            warnings.append(
                {
                    "code": "optional_dependency_missing",
                    "dependency": name,
                    "message": f"{dependency.get('label', name)} 未安装，将使用可用的回退路径。",
                    "hint": dependency.get("install_hint", "可按需安装该依赖。"),
                }
            )
    for group_items in groups.values():
        if group_items and not any(item["available"] for item in group_items):
            first = group_items[0]
            dependency = first.get("dependency", {})
            blocking.append(_missing_issue(str(first["name"]), dependency))

    return {
        "ok": not blocking,
        "blocking_issues": blocking,
        "warnings": warnings,
        "requirements": requirements,
    }


def _supported_routes():
    yield _route("pdf", "translated_pdf", "pdf_translate", requirements=[{"name": "deepseek", "required": True}, {"name": "babeldoc", "required": False}, {"name": "pdf2zh", "required": False}], option_panels=["translate", "advanced"], accept=FORMAT_DEFINITIONS["pdf"]["input"])
    yield _route("pdf", "ocr", "ocr", requirements=[{"name": "tesseract", "required": True}], option_panels=["ocr", "advanced"], accept=FORMAT_DEFINITIONS["pdf"]["input"])
    yield _route("image", "ocr", "ocr", requirements=[{"name": "tesseract", "required": True}], option_panels=["ocr", "advanced"], accept=FORMAT_DEFINITIONS["image"]["input"])
    yield _route("pdf", "md", "extract_markdown", requirements=[{"name": "markitdown", "required": "one-of-markdown"}, {"name": "tesseract", "required": "one-of-markdown"}], option_panels=["ocr", "advanced"], accept=FORMAT_DEFINITIONS["pdf"]["input"], ocrFallback=True)
    yield _route("image", "md", "extract_markdown", requirements=[{"name": "tesseract", "required": True}], option_panels=["ocr", "advanced"], accept=FORMAT_DEFINITIONS["image"]["input"], ocrFallback=True)
    yield _route("pdf", "pdf", "pdf_edit", requirements=[], option_panels=["edit", "advanced"], accept=FORMAT_DEFINITIONS["pdf"]["input"])
    for source in ("word", "ppt", "excel", "md", "html", "image", "data"):
        requirements = []
        if source in {"word", "ppt", "excel"}:
            requirements = [{"name": "libreoffice", "required": True}]
        elif source in {"md", "html", "data"}:
            requirements = [{"name": "playwright", "required": True}]
        accept = FORMAT_DEFINITIONS[source].get("pdf_input") or FORMAT_DEFINITIONS[source]["input"]
        yield _route(source, "pdf", "convert", requirements=requirements, option_panels=[], accept=accept)
    for source in ("word", "ppt", "excel", "data", "html"):
        yield _route(source, "md", "extract_markdown", requirements=[{"name": "markitdown", "required": True}], option_panels=[], accept=FORMAT_DEFINITIONS[source]["input"])


def _route(
    source: str,
    target: str,
    kind: str,
    *,
    requirements: list[dict[str, Any]],
    option_panels: list[str],
    accept: str,
    ocrFallback: bool = False,
) -> dict[str, Any]:
    copy = ROUTE_COPY[kind]
    route: dict[str, Any] = {
        "source": source,
        "target": target,
        "kind": kind,
        "title": f"{_format_label(source)} → {_format_label(target)}",
        "enabled": True,
        "accept": accept,
        "input": FORMAT_DEFINITIONS[source]["detail"],
        "requirements": requirements,
        "optionPanels": option_panels,
        **copy,
    }
    if ocrFallback:
        route["ocrFallback"] = True
    return route


def _format_label(format_name: str) -> str:
    return str(FORMAT_DEFINITIONS.get(format_name, {}).get("label") or format_name)


def _requirements_for_route(route: dict[str, Any] | None, options: dict[str, Any]) -> list[dict[str, Any]]:
    if not route:
        return []
    requirements = [dict(item) for item in route.get("requirements", [])]
    if route.get("kind") == "pdf_translate":
        provider = str(options.get("provider") or "deepseek")
        requirements = [{"name": provider, "required": True}] + [
            item for item in requirements if item.get("name") not in {"deepseek", "openai"}
        ]
    return requirements


def _missing_issue(name: str, dependency: dict[str, Any]) -> dict[str, Any]:
    provider_names = {"deepseek", "openai"}
    return {
        "code": "missing_provider" if name in provider_names else "missing_dependency",
        "dependency": name,
        "message": f"{dependency.get('label', name)} 未配置或不可用。",
        "hint": dependency.get("install_hint", "请安装或配置该依赖。"),
    }


def _file_size(file: Any) -> int:
    try:
        return int(file.get("size", 0))
    except Exception:
        return 0


def _file_allowed(name: str, accept: str) -> bool:
    if not accept:
        return True
    suffix = Path(name).suffix.lower()
    allowed = {item.strip().lower() for item in accept.split(",") if item.strip()}
    return suffix in allowed
