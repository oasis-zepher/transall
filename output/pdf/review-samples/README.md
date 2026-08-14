# Transall App Review sample files

These documents are synthetic and contain no personal, confidential, licensed third-party, or account information.

| File | Intended route |
| --- | --- |
| `research-notes.pdf` | PDF editing, page removal, rotation, reorder, watermark, and preview |
| `appendix.pdf` | Merge after `research-notes.pdf` |
| `scanned-page.pdf` | PDF to OCR; the page is image-only and has no embedded text layer |
| `translation-sample.pdf` | PDF to translated PDF using the review-only provider key |

Regenerate the files with:

```bash
/Users/zephyr/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/generate_review_samples.py
```

Before submission, use copies of these files for App Store screenshots and attach them for App Review only if App Store Connect provides an appropriate review attachment field.
