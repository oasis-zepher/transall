#!/bin/zsh
set -euo pipefail

review_directory=${0:a:h}
repository_directory=${review_directory:h:h:h}
review_build_directory=$(mktemp -d "${TMPDIR:-/tmp}/transall-review-probe.XXXXXX")
trap 'rm -rf -- "$review_build_directory"' EXIT

processor_sources="$repository_directory/native/TransallMac/Sources/TransallMac"
swiftc -parse-as-library -swift-version 5 \
  "$processor_sources/Models.swift" \
  "$processor_sources/NativeCapabilities.swift" \
  "$processor_sources/ProviderCredentialStore.swift" \
  "$processor_sources/NativeDocumentProcessor.swift" \
  "$processor_sources/PDFLayoutTranslation.swift" \
  "$processor_sources/TranslationRecovery.swift" \
  "$processor_sources/MarkdownPDFRenderer.swift" \
  "$review_directory/ReviewProbe.swift" \
  -o "$review_build_directory/probe"
review_output=${1:-$(mktemp -d "${TMPDIR:-/tmp}/transall-review-results.XXXXXX")}
"$review_build_directory/probe" "$review_output"
print -- "Review results: $review_output"
