# macOS App Store screenshot plan

Capture from the signed release candidate at a supported 16:10 size, preferably 2880×1800 or 2560×1600. Keep the same window size and scale across the set.

| Order | Scene | Required visible details |
| --- | --- | --- |
| 1 | Empty workbench | Circular format router, warm document grid, local engine ready, no personal files |
| 2 | PDF editing | Two neutral sample PDFs, merge/edit controls, advanced page fields |
| 3 | OCR result | Completed state, page previews, local Vision log, recognizable output filename |
| 4 | Translation disclosure | PDF → 译文 PDF path, provider picker, clear remote-processing notice; no API key |
| 5 | Settings and privacy | Provider status, Keychain statement, 24-hour cleanup statement, privacy-policy links |

## Screenshot rules

- Use synthetic documents owned by the publisher.
- Use filenames such as `research-notes.pdf` and `scanned-page.pdf`; no real names, IDs, emails, or confidential content.
- Do not show API keys, personal home-folder paths, notifications, menu-bar personal data, or unrelated apps.
- Avoid adding unsupported claims such as “100% private” because translation sends extracted text to a provider.
- Keep copy readable at App Store thumbnail size; do not cover the circular router with large marketing text.
- Capture again if the final signing build changes layout, wording, icon, or supported formats.

Apple's accepted macOS screenshot dimensions can change. Confirm the current list immediately before upload:

- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
