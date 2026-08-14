from __future__ import annotations

import os
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.environ.get("DOCWORK_DATA_DIR", APP_ROOT / "work" / "docwork-data"))


def positive_env_int(name: str, default: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError as exc:
        raise ValueError(f"{name} must be a positive integer") from exc
    if value < 1:
        raise ValueError(f"{name} must be a positive integer")
    return value


MAX_UPLOAD_MB = positive_env_int("DOCWORK_MAX_UPLOAD_MB", 200)
MAX_UPLOAD_BYTES = MAX_UPLOAD_MB * 1024 * 1024
MAX_BROWSER_TEXT_MB = positive_env_int("DOCWORK_MAX_TEXT_RENDER_MB", 25)
MAX_BROWSER_TEXT_BYTES = MAX_BROWSER_TEXT_MB * 1024 * 1024
JOB_TTL_HOURS = positive_env_int("DOCWORK_JOB_TTL_HOURS", 24)
MAX_CONCURRENT_JOBS = positive_env_int("DOCWORK_MAX_JOBS", 2)

OFFICE_EXTENSIONS = {".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx", ".odt", ".odp", ".ods"}
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff"}
MARKDOWN_EXTENSIONS = {".md", ".markdown"}
HTML_EXTENSIONS = {".html", ".htm"}
PDF_EXTENSIONS = {".pdf"}
TEXT_EXTENSIONS = {".txt", ".text", ".csv", ".tsv", ".json", ".xml", ".yaml", ".yml"}
ARCHIVE_EXTENSIONS = {".zip", ".epub"}
