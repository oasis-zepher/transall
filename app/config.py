from __future__ import annotations

import os
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.environ.get("DOCWORK_DATA_DIR", APP_ROOT / "work" / "docwork-data"))
MAX_UPLOAD_BYTES = int(os.environ.get("DOCWORK_MAX_UPLOAD_MB", "200")) * 1024 * 1024
JOB_TTL_HOURS = int(os.environ.get("DOCWORK_JOB_TTL_HOURS", "24"))
HOST = os.environ.get("DOCWORK_HOST", "127.0.0.1")
PORT = int(os.environ.get("DOCWORK_PORT", "8765"))

OFFICE_EXTENSIONS = {".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx", ".odt", ".odp", ".ods"}
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff"}
MARKDOWN_EXTENSIONS = {".md", ".markdown"}
HTML_EXTENSIONS = {".html", ".htm"}
PDF_EXTENSIONS = {".pdf"}
TEXT_EXTENSIONS = {".txt", ".text", ".csv", ".tsv", ".json", ".xml", ".yaml", ".yml"}
ARCHIVE_EXTENSIONS = {".zip", ".epub"}
