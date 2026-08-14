# App Store readiness

## Current status

The native SwiftUI app is self-contained and uses only Apple system frameworks for local document processing. It has App Sandbox entitlements, an App Privacy manifest, a complete macOS AppIcon set, Keychain-backed provider credentials, local task deletion, and 24-hour task-data cleanup. Xcode 26.6 passes 65 Swift tests, the Xcode scheme tests, static analysis, an unsigned universal Release archive for arm64 and x86_64, dependency inspection, and a launch smoke test. The prepared marketing version is 1.0.0.

## Blocking items

| Priority | Item | Required decision or work |
| --- | --- | --- |
| P1 | Individual membership | Complete identity verification, pay for the Apple Developer Program, and wait for the individual's membership to become active. The seller name will be the verified legal name; `Zephyr` remains the brand. |
| P1 | Signing identity | Set the individual's approved Apple Developer Team and final unique bundle identifier, create the Mac App Store distribution identities/profile, and validate Data Protection Keychain access in the signed build. This Mac currently has no valid signing identity. |
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
- Translation retries only temporary network failures and HTTP 408, 425, 429, 500, 502, 503, and 504 responses. It honors bounded `Retry-After` delays, stops after two retries, cancels during backoff, and does not retry authentication failures.
- Translation uses a dedicated ephemeral network session with URL caching, cookies, and shared URL credential storage disabled; individual requests also reject caching and cookies.
- Task-state writes no longer fail silently: processing does not start until the running state is saved, completion/failure/cancellation write errors remain visible, and a complete output can restore its finished state without reprocessing.
- Restart recovery requires a completion receipt written only after the processor returns successfully. A readable but partial PDF without that receipt is never presented as a completed result.
- After a restart, interrupted translation tasks stop with a retryable explanation instead of automatically issuing another provider request. Interrupted local-only tasks still resume automatically.
- Stored task identifiers, input and output names, route-specific input counts, options, state files, and task directories are validated before recovery, preview, or export. Path traversal, symbolic-link substitutions, invalid options, and impossible input counts are rejected, while damaged running metadata becomes a visible, deletable failed task instead of resuming work from unsafe state.
- Settings state that provider keys are stored only in macOS Keychain; delete controls are disabled when no key exists.
- If Keychain reads fail, Settings identifies the read failure, disables credential edits, and offers a retry instead of treating existing keys as empty. Multi-provider saves roll back earlier writes if a later write fails.
- Distribution-signed builds request Data Protection Keychain storage with `WhenUnlockedThisDeviceOnly`; legacy entries migrate after a successful protected write. Unsigned development builds fall back to the legacy keychain when the application-identifier entitlement is unavailable. Both branches have simulated regression coverage; the signed path still requires validation after signing assets exist.
- Local-only document jobs do not access translation credentials. Translation preflight and processing surface Keychain failures separately from an unconfigured key and stop before any provider request.
- Task creation independently rejects unregistered or disabled routes, empty and mismatched input batches, invalid file sizes, overflowing or oversized totals, one-file merge requests, malformed PDF edit options, invalid translation modes or language fields, oversized glossaries, and invalid OCR modes or language lists before creating a task directory. The processor and restart recovery use the same option rules, and persisted tasks use the matching canonical route from the native capability registry.
- Launch and quit leave no Transall process and no TCP listener on port 8765.
- The unsigned archive contains only the executable, Info.plist, AppIcon resources, asset catalog, and privacy manifest; no browser-edition runtime is bundled.
- Image-to-PDF conversion decodes one input at a time, failed imports remove incomplete task directories, and the processor rejects unknown translation providers before network work.
- File selection metadata is read outside the main actor. A mixed valid/invalid batch leaves the existing selection unchanged, directories and symbolic links are rejected with the matching filename, and conflicting route actions remain disabled during inspection.
- The engine independently verifies source and copied inputs are regular non-symbolic-link files, then enforces the 250 MB limit against copied file sizes so stale selection metadata cannot bypass the limit.
- Image decoding is bounded to 3,508 pixels for PDF generation and 2,400 pixels for OCR/Markdown extraction, preserving practical output resolution without fully materializing oversized source images.
- Incomplete, corrupt, or symbolic-link preview caches are regenerated as regular files inside the task directory; corrupt task metadata no longer prevents the user from deleting local task data. Successful, failed, cancelled, and otherwise non-running tasks all expose the same confirmed deletion control.
- Scanned-PDF Markdown extraction and translation open each PDF once for raster access instead of reopening it for every page; damaged or empty PDFs fail with a file-specific error.
- Translation glossaries are limited to 20,000 characters in both preflight and the processing layer, and multiple text inputs are combined without retaining a second array of document contents.
- Input inspection, input copies, and result saves run outside the main actor, preserve security-scoped access, and propagate cancellation; large transfers no longer block the SwiftUI event loop.
- Input file rows use lazy stack rendering inside the workbench scroll view, avoiding eager row creation for large file batches.
- Startup cleanup and manual task deletion run outside the main actor with cancellation propagation. Deletion cancels and waits for any in-flight preview before removing the task directory, so late preview writes cannot recreate deleted local data. While deletion is active, the app disables saving, preview generation, duplicate deletion, and new task submission.
- Cancelled processing tasks remain tracked until their background work exits. Deleting a cancelled task cancels and waits for that processor before removing the task directory, so a late processor write cannot recreate deleted local data.
- PDF preview cache inspection and rendering run outside the main actor with cancellation propagation. Preview failures show the exact error and keep a retry action available; a real-window test verified recovery after replacing a damaged PDF with a valid result.
- Unselected route-state text meets WCAG AA contrast at 4.95:1, and new preview failures request an immediate VoiceOver announcement without moving keyboard focus.
- Keychain reload, save, deletion, and failure messages request VoiceOver announcements without moving keyboard focus; failures use high priority.
- PDF merge, reorder, and watermark operations fail with a page-specific error if a page cannot be copied instead of silently producing an incomplete result.

## Prepared submission material

- [`../../store/INDIVIDUAL_ENROLLMENT.md`](../../store/INDIVIDUAL_ENROLLMENT.md)
- [`../../store/PAID_APP_SUBMISSION_CHECKLIST.md`](../../store/PAID_APP_SUBMISSION_CHECKLIST.md)
- [`../../store/APP_REVIEW_NOTES.md`](../../store/APP_REVIEW_NOTES.md)
- [`../../store/SCREENSHOT_PLAN.md`](../../store/SCREENSHOT_PLAN.md)
- [`../../store/support-site/`](../../store/support-site/)
