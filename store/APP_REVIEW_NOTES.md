# App Review notes draft

Paste the finalized text into App Store Connect. Replace bracketed fields there; do not commit the review credential to this repository.

## Notes for reviewer

Transall is a native macOS document workbench. It does not require a Transall account and does not contain advertising, analytics, or cross-app tracking.

The following features run entirely on the Mac using Apple frameworks:

- PDF merge, delete, rotate, reorder, crop, watermark, and preview;
- OCR using Apple Vision;
- PDF and image text extraction;
- image, Markdown, HTML, TXT, CSV, and JSON conversion to PDF.

PDF translation is the only network feature. When the reviewer explicitly starts a translation task, extracted document text is sent directly to the selected DeepSeek or OpenAI API using the API key entered in Transall Settings. The original PDF file is not uploaded. API keys are stored in the macOS Keychain.

Local task copies, previews, outputs, and logs are stored in the app container and automatically removed after the task becomes more than 24 hours old. Cleanup runs when the app launches and once per hour while it remains open; active processing is retained. The reviewer can delete the current task immediately from the result panel. Original files are never overwritten.

## Review test steps

1. Launch Transall. No sign-in is required.
2. Select `PDF` as the source and `PDF` as the target.
3. Add `output/pdf/review-samples/research-notes.pdf` and `appendix.pdf`, then choose merge or edit.
4. Run the task, inspect the page preview and log, and save the result.
5. Select the result panel's delete action to remove local task data.
6. For OCR, select `PDF → OCR`, add `scanned-page.pdf`, and choose searchable PDF or text.
7. For translation, open Transall Settings, enter the review key below, save it, then select `PDF → 译文 PDF` and add `translation-sample.pdf`.

## Secure review-only values

```text
Provider: [DeepSeek or OpenAI]
API Key: [ENTER ONLY IN APP STORE CONNECT REVIEW INFORMATION]
Usage limit / expiry: [DATE AND LIMIT]
Support contact: [NAME, SUPPORT EMAIL, PHONE]
```

The review key must be newly issued, rate limited, monitored during review, and revoked after approval. Never reuse a production or personal unrestricted key.
