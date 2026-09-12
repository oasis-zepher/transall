#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE_DIR="$PROJECT_DIR/Design/AppIconVariants"
PREVIEW_DIR="$SOURCE_DIR/Previews"

if ! command -v sips >/dev/null 2>&1; then
  echo "sips is required to render AppIcon previews." >&2
  exit 1
fi

mkdir -p "$PREVIEW_DIR"

for source in "$SOURCE_DIR"/[A-F]-*.svg; do
  name=$(basename "$source" .svg)
  sips -s format png -z 512 512 "$source" --out "$PREVIEW_DIR/$name.png" >/dev/null
done

echo "Rendered AppIcon variant previews."
