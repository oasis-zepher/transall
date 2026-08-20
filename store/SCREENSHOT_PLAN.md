# macOS App Store screenshot plan

Capture from the signed release candidate at a supported 16:10 size, preferably 2880×1800 or 2560×1600. Keep the same window size and scale across the set.

| Order | Scene | Required visible details |
| --- | --- | --- |
| 1 | Empty workbench | Circular format router, warm document grid, local engine ready, no personal files |
| 2 | PDF editing | One neutral sample PDF, single-file edit control, advanced page fields; use the appendix only for a separate merge variant |
| 3 | OCR result | Completed state, page previews, local Vision log, recognizable output filename |
| 4 | Translation disclosure | PDF → 译文 PDF path, provider picker, clear remote-processing notice; no API key |
| 5 | Settings and privacy | Provider status, Keychain statement, automatic cleanup after 24 hours, privacy-policy links |

## Prepared synthetic files

Use the files in `output/pdf/review-samples/`:

| Scene | Files |
| --- | --- |
| PDF editing | `research-notes.pdf`; optional merge variant: `research-notes.pdf` + `appendix.pdf` |
| OCR result | `scanned-page.pdf` |
| Translation disclosure | `translation-sample.pdf` |

The generator is `scripts/generate_review_samples.py`. The PDFs have been rendered and visually checked; `scanned-page.pdf` intentionally contains one raster image and no embedded text layer.

## Screenshot rules

- Use synthetic documents owned by the publisher.
- Use filenames such as `research-notes.pdf` and `scanned-page.pdf`; no real names, IDs, emails, or confidential content.
- Do not show API keys, personal home-folder paths, notifications, menu-bar personal data, or unrelated apps.
- Avoid adding unsupported claims such as “100% private” because translation sends extracted text to a provider.
- Keep copy readable at App Store thumbnail size; do not cover the circular router with large marketing text.
- Capture again if the final signing build changes layout, wording, icon, or supported formats.

## Current draft set

The files in `screenshots/draft/` were captured from the unsigned Xcode 26.6 Release build for layout and privacy review. They contain only the synthetic files above. They are not submission assets: the main-window drafts are 1162×768 and the Settings draft is 540×592, so every scene must be recaptured from the signed release candidate at an accepted App Store size.

| File | Scene | Draft size |
| --- | --- | --- |
| `01-empty-workbench.jpg` | Empty workbench | 1162×768 |
| `02-pdf-editing.jpg` | Valid single-file PDF edit with advanced fields | 1162×768 |
| `03-ocr-result.jpg` | Completed local OCR with result preview | 1162×768 |
| `04-translation-disclosure.jpg` | Translation provider and remote-processing disclosure | 1162×768 |
| `05-settings-privacy.jpg` | Blank provider fields and local-retention disclosure | 540×592 |

Apple's accepted macOS screenshot dimensions can change. Confirm the current list immediately before upload:

- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
