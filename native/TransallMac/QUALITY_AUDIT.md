# Transall release quality audit

Audit date: 2026-08-15
Last verified: 2026-08-27
Quality bar: App Store-ready version 1.0
Surfaces: native SwiftUI app and local support/privacy website

## Result

All P1, P2, and P3 findings from the baseline audit remain resolved. All four P2 issues found in the 2026-08-21 follow-up are also resolved: task creation is cancellable, Keychain transactions run off the main actor, the format router adapts to accessibility text sizes, and every support page can bypass repeated navigation. Later P2 findings in same-format route state reporting, unbounded multi-file batches, file-inspection lifecycle, bundle-language metadata, final task status announcements, and active-session result integrity are resolved as well. The 2026-08-27 release-automation follow-up found one additional P1: GitHub Actions tested only the browser edition and did not protect the native app or support site. The workflow now covers strict native formatting and tests, Xcode scheme tests, Release analysis, release metadata, support-site lint/build/render tests, and a high-severity dependency gate. Local reproduction passes, but the new workflow has not run on GitHub because these commits have not been pushed. The later P3 in native formatting enforcement is resolved as well. The current follow-up found one open P2: translation requests do not define a redirect policy, so the URL loading system can follow a provider redirect without the app first rejecting an unexpected destination. External release work remains with the account holder: activate the individual Apple Developer membership, choose and register the final bundle identifier, create signing assets, publish the support site, and complete App Store Connect commercial information.

## Anti-pattern verdict

**Pass — the product does not look generically AI-generated.** The native app and support site consistently use the established light document-workbench language: paper-tinted surfaces, compact controls, precise borders, operational logs, and PDF previews. There are no decorative gradients, glass effects, hero metrics, interchangeable card grids, or unrelated dashboard elements.

## Health score

| # | Dimension | Baseline | Current | Evidence |
| --- | --- | ---: | ---: | --- |
| 1 | Accessibility | 3/4 | 4/4 | Contrast, scalable type, labels, focus, reduced-motion behavior, keyboard targets, status announcements, and repeated-navigation bypasses are covered across both surfaces. |
| 2 | Performance | 2/4 | 4/4 | Byte-heavy work and file metadata inspection are bounded, model-owned, and cancellable from the workbench and app lifecycle. |
| 3 | Responsive design | 3/4 | 4/4 | Native layout changes at 1040 pt, the website reflows at 820 px, and compact website targets meet the release size baseline. |
| 4 | Theming | 4/4 | 4/4 | Both surfaces retain the quiet, light-first document-workbench palette and centralized color tokens. |
| 5 | Anti-patterns | 4/4 | 4/4 | The product keeps its specific document-workbench identity without generic dashboards, decorative gradients, or unrelated cards. |
| **Total** |  | **16/20** | **20/20** | **Excellent; one translation-redirect P2 remains open.** |

## Executive summary

- Audit health score: **20/20 — Excellent**.
- Open findings: **0 P0, 0 P1, 1 P2, 0 P3**.
- All four follow-up P2 findings are resolved and covered by native or rendered-HTML regression tests.
- The release-automation P1 is resolved in the local workflow; remote GitHub Actions execution remains a release gate after push.
- No new privacy, sandboxing, theme, responsive-layout, or AI-aesthetic issue was found. The support-site dependency audit reports zero known vulnerabilities.

## Open follow-up finding

### [P2] Translation requests do not reject provider redirects

- **Location:** `TranslationService.boundedData(for:configuration:maximumBytes:)` creates `BoundedResponseLoader`, whose `URLSessionDataDelegate` bounds response bytes and cancellation but does not implement `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`.
- **Category:** Privacy / reliability / release quality.
- **Impact:** A provider, proxy, or intercepted endpoint can return a redirect. Depending on the status and redirected request produced by the URL loading system, extracted document text may be resent to a destination that Transall did not approve; the app also has no explicit guarantee that its bearer credential will stay on the original provider request.
- **Standard:** Data minimization, secure credential handling, and the product promise that translation text goes only to the user-selected DeepSeek or OpenAI service; no WCAG criterion applies.
- **Recommendation:** Reject every HTTP redirect in the bounded response loader before following it, cancel the session, and return a specific non-retryable provider error explaining that the destination changed. Add a URL-protocol regression proving that the redirected request is never started and its response body is never accepted.
- **Suggested command:** `$harden`, then rerun translation network, cancellation, strict concurrency, and Release checks.

## Resolved follow-up findings

### [P2] Active-session preview and export did not verify the completion receipt

- **Location before the fix:** `NativeDocumentEngine.download(jobID:to:)` and `previewPages(jobID:)` validated a regular task-local output path but did not call the completion-receipt fingerprint check used by restart recovery.
- **Category:** Reliability / release quality.
- **Impact before the fix:** If a completed task result was replaced or modified before preview or export, the active app could use the changed file while still presenting the task as complete. Restarting the app detected the mismatch, but the active session did not.
- **Standard:** Result integrity and secure local-file handling; no WCAG criterion applies.
- **Resolution:** Preview and export now require a bounded, no-follow completion receipt whose output name, byte count, structural validity, and SHA-256 sample fingerprint match. Preview verifies before and after generation and removes its cache on failure. Export hashes the bytes read from the opened source while copying, rejects a replacement or mid-copy change, and preserves the selected destination on failure.
- **Verification:** Regressions replace a valid completed PDF before preview/export and inject a copied-file fingerprint mismatch. Strict SwiftPM and Xcode scheme tests passed 137/137, strict recursive formatting passed, and Release analysis passed.

### [P2] Final task status was not announced to VoiceOver

- **Location:** `ResultWorkbenchView.swift`, where the visible status badge and progress view respond to `model.currentJob`, but the only announcement handler watches `model.previewError`.
- **Category:** Accessibility.
- **Impact before the fix:** A VoiceOver user who started a task received no proactive notification when processing completed, failed, or was cancelled. The user had to navigate back through the output panel to discover the final state and whether a result could be saved.
- **Standard:** WCAG 2.2 Success Criterion 4.1.3 (Status Messages).
- **Resolution:** Completion and cancellation now request medium-priority announcements; failure requests a high-priority announcement with its error and recovery hint. Queued and running updates remain silent, keyboard focus does not move, and announcements are limited to 500 characters.
- **Verification:** The announcement-policy regression covers all five job states, priority, failure context, and the length bound. Strict SwiftPM and Xcode scheme tests passed 137/137, and Release analysis passed.

### [P2] Bundle language metadata contradicted the product language

- **Location:** `Support/Info.plist`, `project.yml`, `Transall.xcodeproj/project.pbxproj`, and the built Release app.
- **Category:** Usability / release quality.
- **Impact before the fix:** The Release bundle resolved `CFBundleDevelopmentRegion` to `en` and had no `CFBundleLocalizations`, while the interface and App Store primary language were Simplified Chinese. macOS and App Store metadata could therefore advertise English support that the product did not provide and omit its actual language.
- **Standard:** Accurate App Store product metadata; no WCAG criterion applies.
- **Resolution:** Set the project development language, `CFBundleDevelopmentRegion`, and `CFBundleLocalizations` to `zh-Hans`; regenerated the committed Xcode project; added exact CI assertions for both plist values.
- **Verification:** Strict SwiftPM tests passed 137/137, Xcode scheme tests passed 137/137, Release analysis passed, and the rebuilt app reports `zh-Hans` with `CFBundleLocalizations = ["zh-Hans"]`.

## Patterns and systemic issues

- File inspection, task creation, and result export have model-owned cancellation lifecycles, and Keychain access is isolated from the main actor.
- Aggregate input bytes and the 256-file batch limit are enforced across selection, preflight, transfer, persistence, and recovery.
- The App Store draft, Xcode project, source plist, CI assertions, and rebuilt Release bundle now identify Simplified Chinese consistently.
- Native text uses semantic SwiftUI styles, including accessibility-size-aware geometry for the circular format router.
- Website semantics, contrast, focus rings, target sizes, and repeated-navigation bypasses share one rendered-HTML contract across all routes.

## Positive findings

- Current foreground/background contrast checks pass: muted text is 4.95:1 on panels and 4.70:1 on paper; primary white text is 5.41:1 on the accent, 6.00:1 on source green, and 10.99:1 on target blue.
- Native controls use explicit labels and values where iconography or status color alone would be ambiguous. Preview errors, Keychain status, and terminal task states request bounded VoiceOver announcements without moving focus.
- The support site uses semantic navigation and main landmarks, a focus-visible skip link, visible focus outlines, 44 px navigation targets, responsive layouts, and reduced-motion handling.
- No unsafe casts, blocking sleeps, TODO markers, or third-party UI dependencies were found in the native source.

## Recommended actions

1. **[P2] `$harden`** — reject translation HTTP redirects before URLSession can send the request to another destination, with a regression that records zero redirected requests.
2. **[P3] `$polish`** — rerun the full native release matrix and synchronize the readiness evidence after the redirect fix.

Push the commits and require the new GitHub Actions jobs to pass before treating CI as verified remotely. Repeat the signed-build, Organizer, and App Store Connect checks after the external account and signing items are available.

## Resolved P1 findings

1. **OCR memory growth** — `NativeDocumentProcessor` now handles PDF pages sequentially, releases each raster image after recognition, and writes searchable pages incrementally.
2. **Ambiguous multiple-file routes** — preflight and the processor require exactly one input for PDF translation and single-document PDF editing; the merge processor independently requires at least two PDFs.
3. **Unsafe overwrite saving** — result saving keeps the displayed result's submitted-original snapshot independent of later input-selection changes and rejects those originals plus their symbolic or hard links. Other existing destinations require standard macOS replacement confirmation. The exporter opens the task result and sibling temporary file without following symbolic links, copies in cancellable 1 MiB chunks, verifies that the source did not change and the copy is complete, then performs the atomic replacement. Cancellation, mutation, and copy errors remove the temporary file while preserving the existing destination. The model owns the active save task, exposes progress and a cancel control, cancels it during termination, and opens Finder only after a successful copy.
4. **Website contrast** — the muted text token now meets WCAG AA for its rendered small-text usage.
5. **Large-file UI blocking** — input imports, result saves, startup and hourly retention checks, and task deletion use cancellable detached work instead of synchronously copying or removing large task data on the main actor.
6. **Release CI coverage** — GitHub Actions now validates native release metadata, strict SwiftPM and Xcode tests, Release analysis, support-site lint/build/render tests, and high-severity npm dependency findings. Workflow permissions are restricted to read-only repository contents, and every job has a timeout.

## Resolved P2 findings

1. **Image orientation** — ImageIO applies JPEG and HEIC orientation metadata before OCR or PDF generation; a regression test verifies rotated dimensions.
2. **Completed-route format state** — after a route is complete, only formats that are valid enabled sources remain selectable.
3. **Website target size** — navigation and language links provide at least a 44 px block-size target without increasing visible density.
4. **Silent PDF page omission** — merge and watermark operations stop with a page-specific error when PDFKit cannot copy or access a page. Rotation and cropping also fail instead of skipping an unreadable requested page. Reordering validates one complete replacement document and uses it directly, removing the redundant second copy pass and its optional page insertion.
5. **Native route-state contrast** — the unselected source and target labels now use the 4.95:1 muted-text token instead of the 1.99:1 border token.
6. **Preview error announcement** — inline preview errors are exposed as one labeled accessibility element and request a high-priority VoiceOver announcement when they appear.
7. **Large input-list rendering** — the input file well uses a `LazyVStack` within the existing outer scroll view, so large batches do not instantiate every file row at once.
8. **Partial and unsafe file selection** — document metadata inspection runs off the main actor; any invalid item rejects the full batch without replacing the current selection, and both the UI and engine reject directories and symbolic links.
9. **Task-creation cancellation** — `AppModel` owns the submission task, captures an immutable route, file, and option snapshot, exposes “取消创建” while preflight and input copying run, and cancels it during termination. Normal cancellation shows no error, incomplete task directories are removed, and a job that completes creation during the cancellation race is cancelled, awaited, and deleted before it can become an inaccessible background task.
10. **Main-actor Keychain work** — a serial `ProviderCredentialWorker` now owns Security framework calls for launch diagnostics, Settings load/save/delete, translation preflight, and processing. Multi-provider save, rollback, and reconciliation remain one isolated transaction; published Settings state remains on the main actor. Delayed-store tests prove the main actor continues while a read or complete save transaction is blocked.
11. **Format-router text scaling** — node labels and the route arrow use semantic SwiftUI fonts. Accessibility text sizes expand nodes from 58 to 78 pt, allow two-line labels without shrinking them, widen the route core, and reduce the orbit radius so controls remain inside the existing 348 pt circular router. A layout-policy regression test covers the accessibility geometry.
12. **Website repeated-navigation bypass** — every support route begins with a focus-visible “跳到主要内容” link targeting the same focusable `main-content` landmark. Rendered HTML tests cover the link, target, source order, and focus-visible CSS on the support, privacy, and publisher pages.
13. **Same-format route state** — a node selected as both source and target now keeps both roles instead of being overwritten by the target state. The node uses the target fill with a source-colored outer ring, and VoiceOver reports “已选为源格式和目标格式”. A state-policy regression test covers the combined and single-role cases.
14. **Unbounded multi-file batches** — every task now accepts at most 256 files. Exact duplicate URLs are removed before metadata inspection, the file picker/menu/drop paths stop accepting additions at capacity, preflight and copy boundaries reject oversized non-UI calls, and restart recovery rejects oversized persisted input lists. The workbench shows the limit next to its byte limit.
15. **Uncancellable file metadata inspection** — `AppModel` now owns one import task, both picker and drop entry points use it, overlapping starts are ignored, and the workbench shows “取消读取”. Explicit and termination cancellation stop inspection silently without publishing a partial selection or replacing the existing file list.
16. **Bundle language metadata** — the Xcode project development language, source plist, CI assertions, and built Release app now declare Simplified Chinese (`zh-Hans`) consistently. The bundle no longer advertises undeclared English support.
17. **Final task status announcement** — completion and cancellation request medium-priority VoiceOver announcements, while failure requests a high-priority announcement with bounded error and recovery context. Queued and running updates remain silent, avoiding repeated status noise.

## Resolved P3 findings

1. Result saving now presents a compact progress indicator and an explicit cancel action instead of disabling the only save control with no way to stop the copy.
2. Removed unsupported PDF replacement fields from the job model.
3. Updated the native README from the beta-era requirement to Xcode 26.6 or a compatible newer release.
4. Added Open Graph assets, per-page social metadata, App Privacy Required Reason coverage for file timestamps, and synthetic review files.
5. Keychain reload, save, deletion, and failure messages now request VoiceOver announcements; errors use high priority and successful status changes use medium priority.
6. Translation provider labels preserve the official `DeepSeek` and `OpenAI` capitalization in the workbench instead of deriving user-facing brands from lowercase API identifiers.
7. File selection is available only after a complete route is chosen. The file well, drag-and-drop, keyboard and accessibility actions, model guard, and **File → 选择文件…** (`⌘O`) command share the same state; the misleading shared-model `New Window` command is removed. A regression policy now verifies that the empty file well accepts Return and Space only while document selection is available.
8. The input heading now uses **FILE** for exactly one selected document and **FILES** for zero or multiple documents. Model regressions cover 0, 1, and 2 files, and an unsigned universal Release smoke test verified **INPUT 1 FILE** after importing `research-notes.pdf` through `⌘O`.
9. Native source and tests now pass Xcode 26.6 `swift-format` in strict recursive mode. The follow-up found 12 findings across five files; targeted formatting removed all of them, and the native CI job runs the same check before compilation.

## Additional reliability hardening

- PDF preview cache checks and rendering now run outside the main actor and propagate task cancellation.
- Preview failures remain visible with a specific message and a retry action instead of silently clearing the preview area.
- Terminal task states request concise VoiceOver announcements without moving focus. Failed-task announcements include the recovery context and are capped at 500 characters; queued and running updates do not interrupt the user.
- Preview results are applied only to the job that requested them, preventing an older task from overwriting a newer task's state.
- Preview cache directories and page images must be regular local entries. Symbolic-link substitutions are discarded and regenerated without reading or modifying the linked target.
- Failed, cancelled, and otherwise non-running tasks expose the same confirmed local-data deletion control as successful tasks; deletion is no longer hidden when a job produces no result file.
- While a result save is active, duplicate saves, task deletion, route replacement, new task submission, and runtime retention cleanup are blocked. User cancellation is treated as a normal outcome without an error alert or Finder reveal, and app termination propagates cancellation to the exporter.
- On launch and once per hour while the app remains open, retention checks remove task directories more than 24 hours after their persisted creation time on a utility-priority task. Runtime checks keep active processing, and removal of an expired current result also clears its preview, warnings, and restoration key. Later preview generation cannot extend retention, recent tasks are not removed because of an older directory timestamp, and orphaned directories fall back to their filesystem timestamp. Manual deletion exposes a busy state, cancels and awaits any in-flight preview, and blocks conflicting result operations until removal finishes. A late preview write cannot recreate deleted task data.
- Cancelled processing tasks remain tracked until they actually exit. Deleting a cancelled task cancels and awaits the processor before directory removal, preventing a late output write from rebuilding deleted task data.
- Translation retries temporary network failures and selected transient HTTP responses at most twice, honors bounded `Retry-After` values, remains cancellable during backoff, and fails authentication errors immediately.
- Translation enforces its 2 MB provider-response limit while receiving data: oversized declared bodies stop before download, and undeclared or chunked bodies are cancelled when the next chunk would cross the bound. Translated chunks that exceed the bounded 4,000-character minimum allowance, eight-times-source expansion, or 100,000-character ceiling are also rejected. Provider error details are normalized and capped at 1,000 characters before persistence, preventing abnormal remote output from inflating page buffers, PDF layout, logs, or task state.
- Translation requests use a dedicated ephemeral `URLSession`; URL caching, cookies, and shared URL credential storage are disabled so provider traffic is not retained by those stores.
- PDF translation extracts and validates all source pages locally before constructing any provider request. It rejects documents over 200 pages or 200,000 source characters with an actionable split-document error, and the processor independently rejects every input count other than one. The workbench discloses these limits next to the provider privacy notice.
- Job-state persistence failures are surfaced for start, completion, processing failure, and cancellation. Work cannot begin before its running state is saved, complete outputs recover without reprocessing, and interrupted translation jobs never auto-resubmit a paid provider request.
- Completed-result recovery now requires a structurally valid output plus a post-processing receipt whose output name, byte count, and bounded SHA-256 content fingerprint still match. A readable replacement with the same filename and size, a partial PDF, or a legacy filename-only receipt cannot be misclassified as finished after a failed state write.
- Failed and cancelled processors remove any incomplete expected output on a utility-priority task, and a cleanup failure is recorded in the visible engine log. Complete results remain intact when only the receipt or final-state persistence step fails, so the existing recovery behavior is preserved.
- Processor success is accepted only when it returns the exact expected task-local path and that path contains a regular, non-symbolic-link result. PDF outputs must also contain a readable page, preventing a missing, damaged, or unexpectedly located file from being marked complete.
- Choosing **Reselect Route** removes the dismissed task's restoration reference, preventing it from returning after relaunch. The task directory is not deleted by this navigation action and remains subject to manual deletion or the 24-hour automatic retention policy.
- Persisted task identifiers, state files, input/output names, route-specific input counts, options, and task directories are checked before use. Recovery cannot follow path traversal or symbolic-link substitutions or resume from invalid options and impossible input counts; malformed running metadata becomes a visible failed task that the user can delete.
- Persisted JSON is bounded before both writing and decoding: task state is limited to 1 MiB, route metadata to 128 KiB, and completion receipts to 16 KiB. Reads open the exact regular file without following symbolic links, stream at most 64 KiB per read, enforce the limit during transfer, and reject files whose size or timestamps change. Startup retention scanning uses the same bounded reader and falls back to the task directory timestamp for oversized or damaged state instead of loading it into memory.
- Newly persisted options are canonicalized for the selected route. Local jobs no longer retain unrelated glossary, watermark, provider, or OCR values from another route, while translation and other option-bearing jobs keep exactly the values their processor and recovery path require.
- Keychain reads and complete mutation transactions run on a serial background actor. One status snapshot supplies both launch diagnostics and provider availability, avoiding duplicate credential reads and inconsistent refresh state; translation processing reads only its selected credential once. Settings rejects overlapping save and delete requests before they can enqueue a transaction based on stale model state. Read failures disable credential editing until a successful reload. Failed multi-provider saves attempt to roll back every started write, including writes that mutate before throwing, then re-read Keychain and report the actual stored state. Failed deletions use the same reconciliation path, and malformed non-UTF-8 credential data is rejected. Local-only jobs do not read translation credentials; translation jobs report Keychain access errors before network work.
- Repeated or overlapping app-start callbacks initialize shared engine, credential, restoration, and retention state only once after a successful start. An engine-start failure can still be retried. Cancellation between asynchronous startup stages stops before publishing later state or starting cleanup, and regression coverage verifies that duplicate or cancelled lifecycle callbacks can be followed by a successful retry.
- Provider keys request Data Protection Keychain storage with `WhenUnlockedThisDeviceOnly`; existing legacy entries migrate without losing the credential, while unsigned development builds retain a tested legacy fallback when the application identity entitlement is unavailable.
- Input copying opens source and destination descriptors without following symbolic links, confirms regular-file status on the opened descriptors, and prechecks the actual source size. It then copies in bounded 1 MiB chunks, enforces the cumulative route limit before every write, detects size changes during transfer, and checks cancellation between chunks. Oversize, changed, failed, or cancelled imports remove the partial destination and every completed copy from the same batch. Text-to-PDF input is capped at 20 MB, while other native routes retain the 250 MB limit; the UI, preflight, streaming copy, and text processor all apply the matching limit before text is loaded.
- Multi-file batches are capped at 256 entries before metadata inspection. Exact repeated URLs do not consume the limit twice; selection actions stop at capacity, and preflight, transfer, persisted metadata, and recovery independently enforce the same bound. Boundary regressions verify that 256 files pass while 257 fail before source files are opened.
- File metadata inspection is retained by `AppModel`, rejects overlapping starts, and is cancelled explicitly or during termination. Cancellation remains a normal outcome: it shows no alert and leaves the prior atomic file selection unchanged.
- Task submission is retained by `AppModel` instead of an unowned view task. Duplicate starts are ignored, the UI keeps a visible cancel action while the immutable submission snapshot is validated and copied, and termination propagates cancellation. If creation returns after cancellation was requested, cleanup runs in a fresh task so the cancelled context cannot prevent the new backend job from being stopped and deleted.
- Task submission locks route selection, route reset, option controls, file picking, drag-and-drop, and input removal until input validation and copying finish. Matching model guards prevent non-UI calls from changing the route or input list during the same interval.
- Task creation runs structural preflight before writing task data. Empty inputs, mismatched extensions, invalid file sizes, overflowing or oversized totals, invalid merge counts, unregistered routes, and malformed PDF edit, translation, or OCR options cannot create a task directory; persisted metadata stores only the matching canonical capability route. Preflight, the processor, and restart recovery share the same route-option validation rules.
- PDF edit validation caps page-selection text at 4,096 characters, crop-box text at 256 characters, and watermark text at 512 characters. Crop coordinates must be finite, preventing unbounded option parsing, oversized repeated annotations, and infinite PDF page bounds.
- Image-to-PDF conversion caps decoded images at 3,508 pixels, while OCR and image-to-Markdown cap them at 2,400 pixels; EXIF orientation remains applied during thumbnail decoding.
- OCR plain-text output and Markdown extraction write recognized pages incrementally instead of retaining the full document text in memory. Multi-page and multi-document regression tests preserve page boundaries, order, and Markdown separators.
- Single-document PDF editing mutates the processor-owned in-memory document instead of cloning every page before applying an operation. Merge retains independent per-page copies, source PDFs remain unchanged on disk, and delete, rotate, reorder, crop, and watermark loops propagate cancellation between pages.

## Verification

| Check | Result |
| --- | --- |
| Swift formatting with Xcode 26.6 | Strict recursive lint passed with zero findings across `Sources` and `Tests` |
| Swift package tests with Xcode 26.6 | 137/137 passed, including strict concurrency with warnings as errors |
| Xcode scheme tests with Xcode 26.6 | 137/137 passed |
| Xcode static analyzer with Xcode 26.6 | Passed with no code findings |
| Release bundle language metadata | `CFBundleDevelopmentRegion = zh-Hans`; `CFBundleLocalizations = ["zh-Hans"]` |
| Unsigned Release build with Xcode 26.6 | Passed; universal `arm64` + `x86_64` app |
| Archive dependency inspection | Apple system frameworks only; no Python, Homebrew, Chromium, Tesseract, OCRmyPDF, PyMuPDF, or BabelDOC payload |
| Archive resources | AppIcon and `PrivacyInfo.xcprivacy` present; privacy manifest passes `plutil` |
| Real native UI smoke test | PDF editing, two-file merge, local Vision OCR, translation disclosure, missing-key error, Keychain settings, visible preview failure/retry, the visible 256-file limit, and the unchanged base workbench after the import-lifecycle change verified |
| OCR output inspection | Generated one-page searchable PDF with an extractable text layer |
| Quit/lifecycle check | App exits and leaves no process or listener on TCP port 8765 |
| Support website | Current ESLint, production build, and 5/5 rendered HTML tests passed. `npm audit --audit-level=high` reports 0 vulnerabilities after the build-dependency update. Earlier desktop and 390 px browser checks had no horizontal overflow or console errors; the current Playwright CLI visual rerun was unavailable because its configured Chrome runtime is not installed. |
| Release workflow | YAML parses locally; the `macos-26` runner documents Xcode 26.6 at the configured path. Strict native formatting, native tests/analysis, and support-site workflow commands pass when reproduced locally. |
| Remote GitHub Actions | Not yet run for these commits; no remote CI success is claimed until they are pushed and the jobs complete. |
| Xcode 26.6 production verification | License accepted; current tests, analysis, and universal Release build passed; earlier archive inspection and launch smoke test passed |
| Code signing | Blocked; this Mac reports zero valid code-signing identities |

Additional reliability coverage verifies that failed result saves preserve the existing destination, saving rejects the submitted original plus symbolic and hard links to it after later input-selection changes while allowing unrelated destinations, failed multi-file imports remove incomplete task directories, mixed selections are rejected atomically, symbolic links are rejected at selection, copy, recovery, preview, and export time, copied-byte counts enforce the route-specific upload limit, and oversized file counts stop before inspection, copying, or recovery. Result-export regressions verify that cancellation removes the sibling temporary copy, same-size source mutation is detected, symbolic-link sources are rejected, and the existing destination remains unchanged in every failure case. Model-level save regressions verify visible busy state, duplicate-save and deletion guards, cancellation without an error or Finder reveal, termination cancellation, state restoration after cancellation, and Finder reveal only after successful download. Submission regressions verify immediate busy state, duplicate-start suppression, immutable inputs and options, explicit and termination cancellation without an error or published job, successful restoration and polling, incomplete-directory removal, and deletion of a backend job created during a cancellation race. Dedicated input-transfer regressions cover rejection before creating an oversized destination, cumulative limits across multiple files, a source growing past the limit during transfer, cancellation propagation, and cleanup of partial and completed batch copies. Persisted-state regressions verify that oversized job state is rejected but remains deletable, oversized route metadata becomes a visible deletable failed task, an oversized otherwise-valid completion receipt cannot recover a translation as finished, and retention cleanup uses directory age without reading oversized state. Oversized text is rejected by preflight, import, and the processor before loading, route or input mutations are rejected while task submission is active, and local task metadata omits unrelated user-entered options. Malformed, oversized, and non-finite PDF edit options fail before processing; invalid persisted options and merge counts cannot resume local work; processor-level input-count checks reject PDF translation and single-document edits with anything other than one PDF and merges with fewer than two PDFs; PDF edit regressions verify that the source file remains unchanged and every reordered page remains present in the requested order without redundant whole-document copying; image conversion writes every input page; oversized images are downsampled with their aspect ratio intact; corrupt preview caches are regenerated; preview failures are visible and retryable; and corrupt task metadata becomes deletable failed state. Path-boundary coverage verifies that stored input and result names cannot escape their task directories, symbolic-link task directories are rejected, and preview links are replaced without changing their targets. Persistence fault injection covers running, completion, failure, and cancellation state writes; restart coverage verifies receipt-backed complete-output recovery, rejection of readable partial PDFs without a receipt, local-task resumption, suppression of automatic translation retries, and removal of a dismissed task's restoration reference when the route is reset. Processor fault injection verifies that partial output is deleted after both processing failure and cancellation without removing a completed result needed for recovery, and that missing or unexpectedly located outputs cannot be accepted as successful results. Credential fault injection verifies load-failure write blocking, partial-save rollback, rejection of overlapping save/delete transactions, Data Protection Keychain migration, unsigned-build fallback, preflight error classification, no credential access for local jobs, clear translation failure before network work, and main-actor progress during delayed read and save transactions. Translation coverage verifies the 200-page and 200,000-character pre-request limits, processor-level single-input enforcement, non-persistent session configuration, streamed response cutoff with and without `Content-Length`, `Retry-After` handling, bounded retries after repeated timeouts, cancellation during backoff, and immediate failure for authentication errors without using a real provider key. Cleanup coverage verifies creation-time retention despite conflicting directory timestamps, filesystem-time cleanup for orphaned directories, periodic runtime removal with current-result state clearing, preservation of active work, deletion of failed and cancelled task data, and waiting for cancelled processing and preview work so neither can recreate the task directory. Long-document coverage also verifies the 20,000-character glossary limit, searchable output from multiple text inputs, and clear rejection of damaged PDFs during Markdown extraction. An end-to-end native-engine test covers input import, processing, and result download through the cancellable background transfer path.

## Submission blockers outside the repository

- Activate the individual Apple Developer membership and finish identity verification.
- Register the final unique bundle identifier; `com.transall.mac` remains provisional.
- Create the Mac App Distribution and installer signing assets, validate Data Protection Keychain save/read/delete behavior, and validate a signed archive in Organizer.
- Supply the verified legal seller name, public support email, domain, Paid Apps Agreement, tax, banking, pricing, territories, and DSA declaration.
- Publish the prepared support/privacy site and provide a rate-limited review API key through App Store Connect.
