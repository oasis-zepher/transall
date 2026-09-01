#!/usr/bin/env bash
set -euo pipefail

readonly expected_uv_version="0.10.12"
readonly actual_uv_version="$(uv --version 2>/dev/null || true)"

if [[ "$actual_uv_version" != "uv $expected_uv_version" && "$actual_uv_version" != "uv $expected_uv_version "* ]]; then
  printf 'Expected uv %s, got %s\n' "$expected_uv_version" "${actual_uv_version:-not installed}" >&2
  exit 1
fi

readonly -a common_args=(
  --python-version 3.13
  --universal
  --generate-hashes
  --no-strip-markers
  --custom-compile-command scripts/compile_python_locks.sh
)

uv pip compile \
  requirements.txt \
  requirements-optional.txt \
  "${common_args[@]}" \
  --output-file requirements.lock

uv pip compile \
  requirements.txt \
  requirements-optional.txt \
  requirements-ci.txt \
  "${common_args[@]}" \
  --output-file requirements-ci.lock
