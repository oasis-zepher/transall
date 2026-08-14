# App Store readiness

## Current status

The native SwiftUI app is self-contained and uses only Apple system frameworks for local document processing. It has App Sandbox entitlements, an App Privacy manifest, a complete macOS AppIcon set, Keychain-backed provider credentials, local task deletion, and 24-hour task-data cleanup. Xcode 26.6 passes 23 Swift tests, the Xcode scheme tests, static analysis, an unsigned universal Release archive for arm64 and x86_64, dependency inspection, and a launch smoke test. The prepared marketing version is 1.0.0.

## Blocking items

| Priority | Item | Required decision or work |
| --- | --- | --- |
| P1 | Individual membership | Complete identity verification, pay for the Apple Developer Program, and wait for the individual's membership to become active. The seller name will be the verified legal name; `Zephyr` remains the brand. |
| P1 | Signing identity | Set the individual's approved Apple Developer Team and final unique bundle identifier, then create the Mac App Store distribution identities/profile. This Mac currently has no valid signing identity. |
| P1 | Commercial agreements | Account Holder must accept the Paid Apps Agreement and complete tax and banking setup. |
| P1 | Published URLs | Publish the prepared support/privacy site after replacing legal-name, domain, and email placeholders. |
| P1 | Store record | Create the App Store Connect app, age rating, categories, pricing, territories, DSA trader status, metadata, screenshots, and App Privacy answers. |
| P1 | Review access | Provide a new rate-limited DeepSeek or OpenAI review key through App Store Connect so translation can be tested. |

The former engine, licensing, helper-signing, and feature-scope P0 items are resolved for the App Store edition: it contains no Python helper, PyMuPDF, LibreOffice, Chromium, OCRmyPDF, Tesseract, or BabelDOC. Those dependencies remain limited to the separately run browser edition.

## Recommended App Store edition

For the first App Store release, keep the app small and predictable:

- PDF merge, delete, rotate, crop, watermark, and preview using PDFKit/Core Graphics.
- Image and text to PDF using native Apple frameworks.
- OCR using Vision.
- PDF translation using the user's DeepSeek or OpenAI key, with explicit disclosure.
- Markdown extraction using native parsers where practical.

Office conversion, full Chromium rendering, OCRmyPDF, and BabelDOC can remain in a separately distributed Pro build until their bundle size, sandbox behavior, and licensing are resolved.

## Build files

- `project.yml` is the source of truth for XcodeGen.
- `Transall.xcodeproj` is generated and committed for direct use in Xcode.
- Debug and Release builds both run in App Sandbox.
- Release archives contain one universal native executable and Apple-owned system-framework links only.

## Verified release candidate behavior

- PDF editing produced a two-page result and PDF merge produced the expected three-page result.
- Vision OCR converted the image-only review sample into a one-page searchable PDF with extractable text.
- Translation clearly discloses that extracted text is sent to the selected provider while the PDF file remains local.
- Starting translation without a configured provider key stops with an actionable local error before any request is sent.
- Settings state that provider keys are stored only in macOS Keychain; delete controls are disabled when no key exists.
- Launch and quit leave no Transall process and no TCP listener on port 8765.
- The unsigned archive contains only the executable, Info.plist, AppIcon resources, asset catalog, and privacy manifest; no browser-edition runtime is bundled.
- Image-to-PDF conversion decodes one input at a time, failed imports remove incomplete task directories, and the processor rejects unknown translation providers before network work.
- Incomplete or corrupt preview caches are regenerated, and corrupt task metadata no longer prevents the user from deleting local task data.
- Scanned-PDF Markdown extraction and translation open each PDF once for raster access instead of reopening it for every page; damaged or empty PDFs fail with a file-specific error.
- Translation glossaries are limited to 20,000 characters in both preflight and the processing layer, and multiple text inputs are combined without retaining a second array of document contents.

## Prepared submission material

- [`../../store/INDIVIDUAL_ENROLLMENT.md`](../../store/INDIVIDUAL_ENROLLMENT.md)
- [`../../store/PAID_APP_SUBMISSION_CHECKLIST.md`](../../store/PAID_APP_SUBMISSION_CHECKLIST.md)
- [`../../store/APP_REVIEW_NOTES.md`](../../store/APP_REVIEW_NOTES.md)
- [`../../store/SCREENSHOT_PLAN.md`](../../store/SCREENSHOT_PLAN.md)
- [`../../store/support-site/`](../../store/support-site/)
