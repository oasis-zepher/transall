#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE="$PROJECT_DIR/Design/AppIcon.svg"
DESTINATION="$PROJECT_DIR/Resources/Assets.xcassets/AppIcon.appiconset"

if ! command -v sips >/dev/null 2>&1; then
  echo "sips is required to generate the macOS AppIcon assets." >&2
  exit 1
fi

if [ ! -f "$SOURCE" ]; then
  echo "Missing AppIcon source: $SOURCE" >&2
  exit 1
fi

mkdir -p "$DESTINATION"

render_icon() {
  size=$1
  filename=$2
  sips -s format png -z "$size" "$size" "$SOURCE" --out "$DESTINATION/$filename" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

echo "Generated AppIcon assets from Design/AppIcon.svg."
