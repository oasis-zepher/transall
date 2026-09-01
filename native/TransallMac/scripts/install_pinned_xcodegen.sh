#!/bin/zsh

set -euo pipefail

readonly xcodegen_version=2.46.0
readonly xcodegen_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806

if (( $# != 1 )); then
  print -u2 -- "Usage: $0 <installation-directory>"
  exit 64
fi

readonly installation_root=$1
if [[ -z "$installation_root" || "$installation_root" == "/" ]]; then
  print -u2 -- "The XcodeGen installation directory must be a dedicated non-root path."
  exit 64
fi

archive_path=""
cleanup() {
  if [[ -n "$archive_path" && -f "$archive_path" ]]; then
    rm -f -- "$archive_path"
  fi
}
trap cleanup EXIT

archive_path=$(mktemp "${TMPDIR:-/tmp}/transall-xcodegen.XXXXXX")
readonly download_url="https://github.com/yonaskolb/XcodeGen/releases/download/${xcodegen_version}/xcodegen.zip"

curl \
  --fail \
  --location \
  --proto '=https' \
  --retry 3 \
  --show-error \
  --silent \
  --tlsv1.2 \
  --output "$archive_path" \
  "$download_url"

readonly downloaded_sha256=$(shasum -a 256 "$archive_path" | cut -d ' ' -f 1)
if [[ "$downloaded_sha256" != "$xcodegen_sha256" ]]; then
  print -u2 -- "XcodeGen ${xcodegen_version} archive checksum mismatch."
  exit 1
fi

mkdir -p -- "$installation_root"
ditto -x -k "$archive_path" "$installation_root"

readonly xcodegen_binary="$installation_root/xcodegen/bin/xcodegen"
readonly installed_version=$("$xcodegen_binary" --version)
if [[ "$installed_version" != "Version: ${xcodegen_version}" ]]; then
  print -u2 -- "Expected XcodeGen ${xcodegen_version}, found: ${installed_version}"
  exit 1
fi

print -r -- "$installation_root/xcodegen/bin"
