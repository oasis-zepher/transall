# App Store readiness

## Current status

The native SwiftUI app is self-contained and uses only Apple system frameworks for local document processing. It has App Sandbox entitlements, an App Privacy manifest, a complete macOS AppIcon set, Keychain-backed provider credentials, local task deletion, and 24-hour task-data cleanup at launch and while the app remains open. On 2026-08-21, Xcode 26.6 passed 102/102 Swift package tests, 102/102 Xcode scheme tests, an unsigned universal Release build for arm64 and x86_64, and static analysis. Earlier release-candidate checks also passed archive dependency inspection and a launch smoke test. The prepared marketing version is 1.0.0.

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
- PDF translation first extracts and checks the entire document locally. A provider request begins only after the document is confirmed to contain no more than 200 pages and 200,000 source characters; exceeding either limit produces a specific split-document recovery instruction without paid network work.
- The translation processor independently requires exactly one PDF, so non-UI callers cannot silently pass extra files that would otherwise be ignored. The workbench shows the page and character limits beside the provider disclosure.
- Translation retries only temporary network failures and HTTP 408, 425, 429, 500, 502, 503, and 504 responses. It honors bounded `Retry-After` delays, stops after two retries, cancels during backoff, and does not retry authentication failures.
- Each translation response is limited to 2 MB while it is received. An oversized declared `Content-Length` is rejected before reading the body; a chunked or undeclared response is cancelled as soon as the next chunk would cross the bound, so the full remote payload is never accumulated first. A translated chunk may use a 4,000-character minimum allowance but cannot exceed eight times its source length or 100,000 characters; abnormal expansion fails before page accumulation and PDF layout. Provider error details are normalized and limited to 1,000 characters before entering task state or logs.
- Translation uses a dedicated ephemeral network session with URL caching, cookies, and shared URL credential storage disabled; individual requests also reject caching and cookies.
- Task-state writes no longer fail silently: processing does not start until the running state is saved, completion/failure/cancellation write errors remain visible, and a complete output can restore its finished state without reprocessing.
- Restart recovery requires a completion receipt written only after the processor returns successfully. The receipt records the output name, byte count, and a bounded SHA-256 content fingerprint; recovery rechecks all three plus the output's structural validity. Missing, legacy filename-only, or mismatched receipts cannot present a readable but replaced or partial PDF as completed.
- If processing fails or is cancelled after writing part of its result, the incomplete output is removed on a utility-priority task. Cleanup failures are visible in the engine log. A successfully generated result is still retained when only its completion receipt or final task-state write fails, preserving restart recovery.
- Before a task is marked complete, the engine verifies that the processor returned the exact expected task-local path and that the output is a regular, non-symbolic-link file; PDF results must also contain a readable page. Missing, damaged, or unexpectedly located results fail instead of appearing as successful tasks.
- After a restart, interrupted translation tasks stop with a retryable explanation instead of automatically issuing another provider request. Interrupted local-only tasks still resume automatically.
- Choosing **Reselect Route** clears the current task's restoration reference, so a task the user dismissed does not reappear on the next launch. This action does not immediately delete its local files; they remain covered by manual deletion and the 24-hour automatic retention cleanup.
- Stored task identifiers, input and output names, route-specific input counts, options, state files, and task directories are validated before recovery, preview, or export. Path traversal, symbolic-link substitutions, invalid options, and impossible input counts are rejected, while damaged running metadata becomes a visible, deletable failed task instead of resuming work from unsafe state.
- New task metadata retains only option values used by the selected conversion path. A local text or image task therefore does not carry forward a glossary, watermark, provider choice, or OCR setting entered for another route; the route-relevant values remain available to processing and recovery.
- Settings state that provider keys are stored only in macOS Keychain; delete controls are disabled when no key exists.
- If Keychain reads fail, Settings identifies the read failure, disables credential edits, and offers a retry instead of treating existing keys as empty. Multi-provider saves attempt to roll back every started write, including a write that changes Keychain before returning an error. Settings re-reads Keychain after failed saves and deletions, reports the actual stored state, and claims restoration only after verifying it. Malformed non-UTF-8 Keychain data is rejected instead of being treated as an API key.
- Distribution-signed builds request Data Protection Keychain storage with `WhenUnlockedThisDeviceOnly`; legacy entries migrate after a successful protected write. Unsigned development builds fall back to the legacy keychain when the application-identifier entitlement is unavailable. Both branches have simulated regression coverage; the signed path still requires validation after signing assets exist.
- Local-only document jobs do not access translation credentials. Translation preflight and processing surface Keychain failures separately from an unconfigured key and stop before any provider request.
- Task creation independently rejects unregistered or disabled routes, empty and mismatched input batches, invalid file sizes, overflowing or oversized totals, one-file merge requests, malformed PDF edit options, invalid translation modes or language fields, oversized glossaries, and invalid OCR modes or language lists before creating a task directory. The processor and restart recovery use the same option rules, and persisted tasks use the matching canonical route from the native capability registry.
- PDF edit page-selection fields are limited to 4,096 characters, crop-box text to 256 characters, and watermark text to 512 characters. Crop coordinates must also be finite, so values such as `inf` cannot reach PDFKit or be persisted as runnable task options.
- While task creation is copying and validating input files, the route selector, route reset, option controls, file picker, drag-and-drop target, and input removal controls remain locked. Model-level guards also reject route or input mutations, preventing a late task result from appearing under a route the user changed during submission.
- Launch and quit leave no Transall process and no TCP listener on port 8765.
- The 5.4 MB unsigned universal archive contains only the executable, Info.plist, AppIcon resources, asset catalog, and privacy manifest; no browser-edition runtime is bundled.
- Image-to-PDF conversion decodes one input at a time, failed imports remove incomplete task directories, and the processor rejects unknown translation providers before network work.
- File selection metadata is read outside the main actor. A mixed valid/invalid batch leaves the existing selection unchanged, directories and symbolic links are rejected with the matching filename, and conflicting route actions remain disabled during inspection.
- File selection requires a complete enabled route at both the UI and model layers. Before that point, clicks, drops, keyboard focus, accessibility actions, and **File → 选择文件…** are unavailable. Afterward, `⌘O` opens the route-filtered importer; the default `New Window` command is removed because all workbench windows would otherwise share one task model.
- The engine opens source and destination descriptors without following symbolic links and verifies the opened descriptors are regular files. Text-to-PDF input is limited to 20 MB to bound UTF-8 decoding, combined-text storage, and PDF layout memory; other native routes retain the 250 MB limit. The route-specific limit is enforced during selection and task preflight, checked against the opened source size, enforced before each 1 MiB chunk is written, and checked again by the text processor before loading data. Source growth, cancellation, or any copy error stops transfer and removes partial and completed batch copies, so stale metadata and non-UI callers cannot bypass the limit or leave task data behind.
- Image decoding is bounded to 3,508 pixels for PDF generation and 2,400 pixels for OCR/Markdown extraction, preserving practical output resolution without fully materializing oversized source images.
- Incomplete, corrupt, or symbolic-link preview caches are regenerated as regular files inside the task directory; corrupt task metadata no longer prevents the user from deleting local task data. Successful, failed, cancelled, and otherwise non-running tasks all expose the same confirmed deletion control.
- Scanned-PDF Markdown extraction and translation open each PDF once for raster access instead of reopening it for every page; damaged or empty PDFs fail with a file-specific error.
- OCR plain-text output and Markdown extraction write each completed page directly to the result file instead of retaining all recognized page text in memory. Regression coverage verifies OCR page boundaries and Markdown page/document ordering.
- Translation glossaries are limited to 20,000 characters in both preflight and the processing layer, and multiple text inputs are combined without retaining a second array of document contents.
- Input inspection, input copies, and result saves run outside the main actor, preserve security-scoped access, and propagate cancellation; large transfers no longer block the SwiftUI event loop.
- Result saving retains an immutable snapshot of the originals submitted for the displayed result, even if the editable input selection later changes. Saving refuses those originals and any symbolic or hard link to them until the result task is reset or removed. The save panel explains this boundary; replacing another existing destination still requires the standard macOS confirmation, and the atomic copy path preserves that destination if the new copy fails.
- Input file rows use lazy stack rendering inside the workbench scroll view, avoiding eager row creation for large file batches.
- Startup cleanup, hourly runtime retention checks, and manual task deletion run outside the main actor with cancellation propagation. Automatic cleanup uses the persisted task creation time, so later preview generation cannot extend the 24-hour retention window and an old directory timestamp cannot delete a recent task early; orphaned directories fall back to their filesystem timestamp. Runtime checks preserve active processing and clear the current result, preview, warnings, and restoration key when an expired finished task is removed. Deletion cancels and waits for any in-flight preview before removing the task directory, so late preview writes cannot recreate deleted local data. While deletion is active, the app disables saving, preview generation, duplicate deletion, and new task submission.
- Cancelled processing tasks remain tracked until their background work exits. Deleting a cancelled task cancels and waits for that processor before removing the task directory, so a late processor write cannot recreate deleted local data.
- PDF preview cache inspection and rendering run outside the main actor with cancellation propagation. Preview failures show the exact error and keep a retry action available; a real-window test verified recovery after replacing a damaged PDF with a valid result.
- Unselected route-state text meets WCAG AA contrast at 4.95:1, and new preview failures request an immediate VoiceOver announcement without moving keyboard focus.
- Keychain reload, save, deletion, and failure messages request VoiceOver announcements without moving keyboard focus; failures use high priority.
- Single-document PDF editing works on the processor-owned in-memory document instead of copying every source page before editing. Merge still copies each page into an independent result, and regression coverage verifies that editing never modifies the source PDF on disk.
- Delete, rotate, reorder, crop, and watermark loops check cancellation between pages. Rotation and cropping now fail with a page-specific error if PDFKit cannot retrieve a requested page instead of silently skipping it.
- The processing layer independently requires exactly one input for single-document PDF editing and at least two inputs for PDF merge, protecting non-UI and recovered task entry points.
- PDF merge and watermark operations fail with a page-specific error if a page cannot be copied or accessed. Reordering validates and copies every requested page once, then uses that complete replacement document directly instead of performing a second optional-copy pass that could omit a page; regression tests verify page count, text order, input-count validation, and source-file preservation.

## Prepared submission material

- [`../../store/INDIVIDUAL_ENROLLMENT.md`](../../store/INDIVIDUAL_ENROLLMENT.md)
- [`../../store/PAID_APP_SUBMISSION_CHECKLIST.md`](../../store/PAID_APP_SUBMISSION_CHECKLIST.md)
- [`../../store/APP_REVIEW_NOTES.md`](../../store/APP_REVIEW_NOTES.md)
- [`../../store/SCREENSHOT_PLAN.md`](../../store/SCREENSHOT_PLAN.md)
- [`../../store/screenshots/draft/`](../../store/screenshots/draft/)
- [`../../store/support-site/`](../../store/support-site/)
