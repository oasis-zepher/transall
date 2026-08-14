# App Store readiness

## Current status

The native SwiftUI client has a generated Xcode app project, release sandbox entitlements, an App Privacy manifest, a complete macOS AppIcon set, Keychain-backed provider credentials, and local task deletion. It is not yet ready to upload to App Store Connect because the document engine is not self-contained.

## Blocking items

| Priority | Item | Required decision or work |
| --- | --- | --- |
| P0 | Bundled engine | Package the Python runtime and supported libraries as the signed `transall-backend` auxiliary executable, or replace the sidecar with native Swift implementations. The release cannot depend on `uv`, Homebrew, or tools installed elsewhere on the user's Mac. |
| P0 | PyMuPDF license | PyMuPDF is AGPL-3.0 or commercially licensed. Obtain an Artifex commercial license or replace it with PDFKit/Core Graphics before proprietary App Store distribution. |
| P0 | Sandboxed helper validation | Sign the helper and every nested framework, then verify conversion, cancellation, downloads, and localhost communication inside the release App Sandbox. |
| P1 | Feature scope | LibreOffice, Chromium, OCRmyPDF, Tesseract, and BabelDOC substantially increase bundle size and license review. Decide which engines ship in the App Store edition. |
| P1 | Signing identity | Set a unique bundle identifier and Apple Developer team, then create the Mac App Store distribution profile. |
| P1 | Store records | Create the App Store Connect app, age rating, category, support URL, published privacy-policy URL, screenshots, description, and App Privacy answers. |

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
- Debug builds are unsandboxed so the source-checkout sidecar can run.
- Release builds use `Support/Transall.entitlements` and must include a signed helper before archive validation.
