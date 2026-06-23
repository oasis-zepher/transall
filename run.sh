#!/usr/bin/env bash
set -euo pipefail
python -m uvicorn app.main:app --host 127.0.0.1 --port "${DOCWORK_PORT:-8765}"
