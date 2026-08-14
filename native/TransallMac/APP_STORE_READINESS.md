# App Store readiness

## Current status

The native SwiftUI app is self-contained and uses only Apple system frameworks for local document processing. It has App Sandbox entitlements, an App Privacy manifest, a complete macOS AppIcon set, Keychain-backed provider credentials, local task deletion, and 24-hour task-data cleanup. Unsigned Debug and Release builds pass for arm64 and x86_64.

## Blocking items

| Priority | Item | Required decision or work |
| --- | --- | --- |
| P1 | Signing identity | Set a unique bundle identifier and Apple Developer team, then create the Mac App Store distribution profile. |
| P1 | Store records | Create the App Store Connect app, age rating, category, support URL, published privacy-policy URL, screenshots, description, and App Privacy answers. |

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
