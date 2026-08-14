# Transall release quality audit

Audit date: 2026-08-15
Quality bar: App Store-ready version 1.0
Surfaces: native SwiftUI app and local support/privacy website

## Result

All P1, P2, and P3 product-quality findings from the baseline audit are resolved. Xcode 26.6 production-toolchain verification also passes. The remaining work is account-holder work: activate the individual Apple Developer membership, choose and register the final bundle identifier, create signing assets, publish the support site, and complete App Store Connect commercial information.

## Health score

| # | Dimension | Baseline | Final | Evidence |
| --- | --- | ---: | ---: | --- |
| 1 | Accessibility | 3/4 | 4/4 | Support-site and native state text reach WCAG AA contrast; navigation targets are at least 44 px, and native controls expose labels, values, focus, reduced-motion behavior, preview-error announcements, and Keychain status announcements. |
| 2 | Performance | 2/4 | 4/4 | OCR and image-to-PDF conversion process one bounded raster page at a time; oversized images are downsampled for their target use, input metadata inspection is asynchronous and input rows are lazy, scanned-PDF routes reuse one raster document handle per input, and large file transfers, PDF previews, retention checks, and task deletion run outside the main actor. |
| 3 | Responsive design | 3/4 | 4/4 | Native layout changes at 1040 pt, the website reflows at 820 px, and compact website targets meet the release size baseline. |
| 4 | Theming | 4/4 | 4/4 | Both surfaces retain the quiet, light-first document-workbench palette and centralized color tokens. |
| 5 | Anti-patterns | 4/4 | 4/4 | The product keeps its specific document-workbench identity without generic dashboards, decorative gradients, or unrelated cards. |
| **Total** |  | **16/20** | **20/20** | **Internal product-quality findings resolved; external submission prerequisites remain.** |

## Resolved P1 findings

1. **OCR memory growth** — `NativeDocumentProcessor` now handles PDF pages sequentially, releases each raster image after recognition, and writes searchable pages incrementally.
2. **Ambiguous multiple-file routes** — preflight requires exactly one input for PDF translation and single-document PDF editing; merge mode still accepts multiple PDFs.
3. **Unsafe overwrite saving** — result saving copies to a sibling temporary file and uses atomic replacement, preserving an existing destination if the new copy fails.
4. **Website contrast** — the muted text token now meets WCAG AA for its rendered small-text usage.
5. **Large-file UI blocking** — input imports, result saves, startup and hourly retention checks, and task deletion use cancellable detached work instead of synchronously copying or removing up to 250 MB on the main actor.

## Resolved P2 findings

1. **Image orientation** — ImageIO applies JPEG and HEIC orientation metadata before OCR or PDF generation; a regression test verifies rotated dimensions.
2. **Completed-route format state** — after a route is complete, only formats that are valid enabled sources remain selectable.
3. **Website target size** — navigation and language links provide at least a 44 px block-size target without increasing visible density.
4. **Silent PDF page omission** — merge, reorder, and watermark operations now stop with a page-specific error when PDFKit cannot copy a page.
5. **Native route-state contrast** — the unselected source and target labels now use the 4.95:1 muted-text token instead of the 1.99:1 border token.
6. **Preview error announcement** — inline preview errors are exposed as one labeled accessibility element and request a high-priority VoiceOver announcement when they appear.
7. **Large input-list rendering** — the input file well uses a `LazyVStack` within the existing outer scroll view, so large batches do not instantiate every file row at once.
8. **Partial and unsafe file selection** — document metadata inspection runs off the main actor; any invalid item rejects the full batch without replacing the current selection, and both the UI and engine reject directories and symbolic links.

## Resolved P3 findings

1. Removed the unused `AppModel.isImporting` state.
2. Removed unsupported PDF replacement fields from the job model.
3. Updated the native README from the beta-era requirement to Xcode 26.6 or a compatible newer release.
4. Added Open Graph assets, per-page social metadata, App Privacy Required Reason coverage for file timestamps, and synthetic review files.
5. Keychain reload, save, deletion, and failure messages now request VoiceOver announcements; errors use high priority and successful status changes use medium priority.

## Additional reliability hardening

- PDF preview cache checks and rendering now run outside the main actor and propagate task cancellation.
- Preview failures remain visible with a specific message and a retry action instead of silently clearing the preview area.
- Preview results are applied only to the job that requested them, preventing an older task from overwriting a newer task's state.
- Preview cache directories and page images must be regular local entries. Symbolic-link substitutions are discarded and regenerated without reading or modifying the linked target.
- Failed, cancelled, and otherwise non-running tasks expose the same confirmed local-data deletion control as successful tasks; deletion is no longer hidden when a job produces no result file.
- On launch and once per hour while the app remains open, retention checks remove task directories more than 24 hours after their persisted creation time on a utility-priority task. Runtime checks keep active processing, and removal of an expired current result also clears its preview, warnings, and restoration key. Later preview generation cannot extend retention, recent tasks are not removed because of an older directory timestamp, and orphaned directories fall back to their filesystem timestamp. Manual deletion exposes a busy state, cancels and awaits any in-flight preview, and blocks conflicting result operations until removal finishes. A late preview write cannot recreate deleted task data.
- Cancelled processing tasks remain tracked until they actually exit. Deleting a cancelled task cancels and awaits the processor before directory removal, preventing a late output write from rebuilding deleted task data.
- Translation retries temporary network failures and selected transient HTTP responses at most twice, honors bounded `Retry-After` values, remains cancellable during backoff, and fails authentication errors immediately.
- Translation requests use a dedicated ephemeral `URLSession`; URL caching, cookies, and shared URL credential storage are disabled so provider traffic is not retained by those stores.
- Job-state persistence failures are surfaced for start, completion, processing failure, and cancellation. Work cannot begin before its running state is saved, complete outputs recover without reprocessing, and interrupted translation jobs never auto-resubmit a paid provider request.
- Completed-result recovery now requires both a valid output and a post-processing completion receipt, preventing a readable partial PDF from being misclassified as finished after a failed state write.
- Persisted task identifiers, state files, input/output names, route-specific input counts, options, and task directories are checked before use. Recovery cannot follow path traversal or symbolic-link substitutions or resume from invalid options and impossible input counts; malformed running metadata becomes a visible failed task that the user can delete.
- Keychain read failures disable credential editing until a successful reload, and a partial multi-provider save is rolled back. Local-only jobs no longer read translation credentials; translation jobs report Keychain access errors before network work.
- Provider keys request Data Protection Keychain storage with `WhenUnlockedThisDeviceOnly`; existing legacy entries migrate without losing the credential, while unsigned development builds retain a tested legacy fallback when the application identity entitlement is unavailable.
- Input copying rechecks regular-file status and the actual copied byte count, preventing changed files or non-UI callers from bypassing the 250 MB limit or placing symbolic links in a task directory.
- Task creation runs structural preflight before writing task data. Empty inputs, mismatched extensions, invalid file sizes, overflowing or oversized totals, invalid merge counts, unregistered routes, and malformed PDF edit, translation, or OCR options cannot create a task directory; persisted metadata stores only the matching canonical capability route. Preflight, the processor, and restart recovery share the same route-option validation rules.
- Image-to-PDF conversion caps decoded images at 3,508 pixels, while OCR and image-to-Markdown cap them at 2,400 pixels; EXIF orientation remains applied during thumbnail decoding.

## Verification

| Check | Result |
| --- | --- |
| Swift package tests with Xcode 26.6 | 66/66 passed, including strict concurrency with warnings as errors |
| Xcode scheme tests with Xcode 26.6 | 66/66 passed |
| Xcode static analyzer with Xcode 26.6 | Passed with no code findings |
| Unsigned Release archive with Xcode 26.6 | Passed; universal `arm64` + `x86_64` executable |
| Archive dependency inspection | Apple system frameworks only; no Python, Homebrew, Chromium, Tesseract, OCRmyPDF, PyMuPDF, or BabelDOC payload |
| Archive resources | AppIcon and `PrivacyInfo.xcprivacy` present; privacy manifest passes `plutil` |
| Real native UI smoke test | PDF editing, two-file merge, local Vision OCR, translation disclosure, missing-key error, Keychain settings, visible preview failure, and successful preview retry verified |
| OCR output inspection | Generated one-page searchable PDF with an extractable text layer |
| Quit/lifecycle check | App exits and leaves no process or listener on TCP port 8765 |
| Support website | ESLint passed; production build passed; 4/4 rendered HTML tests passed |
| Xcode 26.6 production verification | License accepted; tests, analysis, archive, dependency inspection, and launch smoke test passed |
| Code signing | Blocked; this Mac reports zero valid code-signing identities |

Additional reliability coverage verifies that failed result saves preserve the existing destination, failed multi-file imports remove incomplete task directories, mixed selections are rejected atomically, symbolic links are rejected at selection, copy, recovery, preview, and export time, copied byte counts enforce the upload limit, malformed PDF edit, translation, and OCR options fail before processing, invalid persisted options and merge counts cannot resume local work, image conversion writes every input page, oversized images are downsampled with their aspect ratio intact, corrupt preview caches are regenerated, preview failures are visible and retryable, and corrupt task metadata becomes deletable failed state. Path-boundary coverage verifies that stored input and result names cannot escape their task directories, symbolic-link task directories are rejected, and preview links are replaced without changing their targets. Persistence fault injection covers running, completion, failure, and cancellation state writes; restart coverage verifies receipt-backed complete-output recovery, rejection of readable partial PDFs without a receipt, local-task resumption, and suppression of automatic translation retries. Credential fault injection verifies load-failure write blocking, partial-save rollback, Data Protection Keychain migration, unsigned-build fallback, preflight error classification, no credential access for local jobs, and clear translation failure before network work. Translation coverage verifies the non-persistent session configuration, `Retry-After` handling, bounded retries after repeated timeouts, cancellation during backoff, and immediate failure for authentication errors without using a real provider key. Cleanup coverage verifies creation-time retention despite conflicting directory timestamps, filesystem-time cleanup for orphaned directories, periodic runtime removal with current-result state clearing, preservation of active work, deletion of failed and cancelled task data, and waiting for cancelled processing and preview work so neither can recreate the task directory. Long-document coverage also verifies the 20,000-character glossary limit, searchable output from multiple text inputs, and clear rejection of damaged PDFs during Markdown extraction. An end-to-end native-engine test covers input import, processing, and result download through the cancellable background transfer path.

## Submission blockers outside the repository

- Activate the individual Apple Developer membership and finish identity verification.
- Register the final unique bundle identifier; `com.transall.mac` remains provisional.
- Create the Mac App Distribution and installer signing assets, validate Data Protection Keychain save/read/delete behavior, and validate a signed archive in Organizer.
- Supply the verified legal seller name, public support email, domain, Paid Apps Agreement, tax, banking, pricing, territories, and DSA declaration.
- Publish the prepared support/privacy site and provide a rate-limited review API key through App Store Connect.
