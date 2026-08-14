# App Store readiness

## Current status

The native SwiftUI app is self-contained and uses only Apple system frameworks for local document processing. It has App Sandbox entitlements, an App Privacy manifest, a complete macOS AppIcon set, Keychain-backed provider credentials, local task deletion, and 24-hour task-data cleanup. Unsigned Debug and universal Release builds pass for arm64 and x86_64. The prepared marketing version is 1.0.0.

## Blocking items

| Priority | Item | Required decision or work |
| --- | --- | --- |
| P1 | Individual membership | Complete identity verification, pay for the Apple Developer Program, and wait for the individual's membership to become active. The seller name will be the verified legal name; `Zephyr` remains the brand. |
| P1 | Signing identity | Set the individual's approved Apple Developer Team and final unique bundle identifier, then create the Mac App Store distribution identities/profile. This Mac currently has no valid signing identity. |
| P1 | Production Xcode | Build and upload with an Apple-supported release Xcode. Current verification used Xcode 27 Beta. |
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

## Prepared submission material

- `store/INDIVIDUAL_ENROLLMENT.md`
- `store/PAID_APP_SUBMISSION_CHECKLIST.md`
- `store/APP_REVIEW_NOTES.md`
- `store/SCREENSHOT_PLAN.md`
- `store/support-site/`
