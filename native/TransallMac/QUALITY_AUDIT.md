# Transall release quality audit

Audit date: 2026-08-15
Last verified: 2026-08-21
Quality bar: App Store-ready version 1.0
Surfaces: native SwiftUI app and local support/privacy website

## Result

All P1, P2, and P3 findings from the baseline audit remain resolved. A 2026-08-21 follow-up found four new P2 issues: task creation cannot be cancelled while large inputs are copied, Keychain work is synchronous on the main actor, the format router uses fixed small type, and the support site has no bypass link around repeated navigation. Xcode 26.6 verification still passes. External release work remains with the account holder: activate the individual Apple Developer membership, choose and register the final bundle identifier, create signing assets, publish the support site, and complete App Store Connect commercial information.

## Anti-pattern verdict

**Pass — the product does not look generically AI-generated.** The native app and support site consistently use the established light document-workbench language: paper-tinted surfaces, compact controls, precise borders, operational logs, and PDF previews. There are no decorative gradients, glass effects, hero metrics, interchangeable card grids, or unrelated dashboard elements.

## Health score

| # | Dimension | Baseline | Current | Evidence |
| --- | --- | ---: | ---: | --- |
| 1 | Accessibility | 3/4 | 3/4 | Contrast, labels, state announcements, focus, and reduced-motion behavior are strong, but the 9–10 pt format-node labels do not use semantic scalable type and the website has no skip link around repeated navigation. |
| 2 | Performance | 2/4 | 3/4 | Heavy document work is bounded and runs outside the main actor, but the UI does not own or expose cancellation for the potentially 250 MB input-copy stage, and Security framework reads/writes remain synchronous on the main actor. |
| 3 | Responsive design | 3/4 | 4/4 | Native layout changes at 1040 pt, the website reflows at 820 px, and compact website targets meet the release size baseline. |
| 4 | Theming | 4/4 | 4/4 | Both surfaces retain the quiet, light-first document-workbench palette and centralized color tokens. |
| 5 | Anti-patterns | 4/4 | 4/4 | The product keeps its specific document-workbench identity without generic dashboards, decorative gradients, or unrelated cards. |
| **Total** |  | **16/20** | **18/20** | **Excellent foundation; four P2 follow-up items remain before the next release audit.** |

## Executive summary

- Audit health score: **18/20 — Excellent**.
- Open findings: **0 P0, 0 P1, 4 P2, 0 P3**.
- Highest-priority work is task-submission ownership and cancellation because the engine already supports cancellable chunked copies but the UI cannot request cancellation during that stage.
- No new privacy, sandboxing, dependency, theme, responsive-layout, or AI-aesthetic issue was found.

## Open follow-up findings

### [P2] Task creation has no cancellation lifecycle

- **Location:** `InputWorkbenchView.actionBar`, `AppModel.runJob`, `AppModel.prepareForTermination`, and `NativeDocumentEngine.createJob` / `copyInputs`.
- **Category:** Performance / Interaction reliability.
- **Impact:** After the user starts a task, copying up to 250 MB of input can continue with only a disabled “正在预检” button. `currentJob` does not exist yet, so “取消任务” is unavailable. The initiating SwiftUI `Task` is not retained by `AppModel`, and termination does not cancel it directly. A cancellation would also currently enter the generic error path.
- **Recommendation:** Let `AppModel` own the submission task, expose a normal cancel action during validation and copying, cancel and await it during explicit cancellation, propagate termination cancellation, suppress cancellation alerts, and verify partial task-directory cleanup.
- **Suggested command:** `$harden`.

### [P2] Keychain operations run synchronously on the main actor

- **Location:** `ProviderCredentialStoring`, `ProviderCredentialStore`, `ProviderSettingsModel.reload/save/remove`, and `NativeDocumentEngine.credentialStatus` / translation preflight.
- **Category:** Performance.
- **Impact:** `SecItemCopyMatching`, update, add, delete, migration, and rollback can run while the SwiftUI main actor is occupied. Normal calls are usually short, but Keychain contention, access prompts, or repeated rollback work can visibly stall launch, Settings, or translation preflight.
- **Recommendation:** Move complete Keychain transactions to an isolated async worker while keeping published settings state on the main actor. Preserve the current rollback and reconciliation guarantees, and add delayed-store tests proving the UI actor can continue making progress.
- **Suggested command:** `$optimize`.

### [P2] Format-router labels do not scale with accessibility text size

- **Location:** `FormatRouterView.FormatNode` and the route-core arrow label.
- **Category:** Accessibility.
- **Impact:** The primary route controls use fixed 9–10 pt text and may shrink to roughly 7 pt through `minimumScaleFactor`. Users who increase text size still receive the same small labels, making the most important controls harder to read even though VoiceOver labels are present.
- **WCAG/standard:** WCAG 1.4.4 Resize Text principle; macOS accessibility text-size expectations.
- **Recommendation:** Use semantic scalable fonts, allow short two-line labels or adapt node geometry at larger dynamic type sizes, and keep the existing circular-router identity.
- **Suggested command:** `$adapt`.

### [P2] Support pages cannot bypass repeated navigation

- **Location:** `store/support-site/app/layout.tsx`, `site-chrome.tsx`, and `globals.css`.
- **Category:** Accessibility.
- **Impact:** Keyboard and switch-control users must traverse the wordmark and navigation links before reaching `<main>` on every page. The repeated block is small but still lacks a direct bypass mechanism.
- **WCAG/standard:** WCAG 2.4.1 Bypass Blocks (Level A).
- **Recommendation:** Add a visually hidden “跳到主要内容” link that becomes visible on focus, give the shared `<main>` target a stable identifier, and cover it in the rendered HTML tests.
- **Suggested command:** `$adapt`.

## Patterns and systemic issues

- Backend cancellation support is stronger than UI task ownership. Result export now has a complete lifecycle, while task submission still depends on an unretained view-created task.
- Most native text uses semantic SwiftUI styles; the fixed-size circular-router labels are the remaining exception in a primary workflow.
- Website semantics, contrast, focus rings, and target sizes are covered, but repeated-navigation bypass was omitted from the current HTML contract.

## Positive findings

- Current foreground/background contrast checks pass: muted text is 4.95:1 on panels and 4.70:1 on paper; primary white text is 5.41:1 on the accent, 6.00:1 on source green, and 10.99:1 on target blue.
- Native controls use explicit labels and values where iconography or status color alone would be ambiguous. Preview and Keychain failures request VoiceOver announcements without moving focus.
- The support site uses semantic navigation and main landmarks, visible focus outlines, 44 px navigation targets, responsive layouts, and reduced-motion handling.
- No unsafe casts, blocking sleeps, TODO markers, or third-party UI dependencies were found in the native source.

## Recommended actions

1. **[P2] `$harden`** — make task creation model-owned and cancellable through input copy, termination, and cleanup.
2. **[P2] `$optimize`** — move atomic Keychain transactions off the main actor without weakening rollback behavior.
3. **[P2] `$adapt`** — support accessibility text sizing in the circular router and add the website bypass link.
4. **[P3] `$polish`** — rerun native and website interaction checks after the three fixes.

## Resolved P1 findings

1. **OCR memory growth** — `NativeDocumentProcessor` now handles PDF pages sequentially, releases each raster image after recognition, and writes searchable pages incrementally.
2. **Ambiguous multiple-file routes** — preflight and the processor require exactly one input for PDF translation and single-document PDF editing; the merge processor independently requires at least two PDFs.
3. **Unsafe overwrite saving** — result saving keeps the displayed result's submitted-original snapshot independent of later input-selection changes and rejects those originals plus their symbolic or hard links. Other existing destinations require standard macOS replacement confirmation. The exporter opens the task result and sibling temporary file without following symbolic links, copies in cancellable 1 MiB chunks, verifies that the source did not change and the copy is complete, then performs the atomic replacement. Cancellation, mutation, and copy errors remove the temporary file while preserving the existing destination. The model owns the active save task, exposes progress and a cancel control, cancels it during termination, and opens Finder only after a successful copy.
4. **Website contrast** — the muted text token now meets WCAG AA for its rendered small-text usage.
5. **Large-file UI blocking** — input imports, result saves, startup and hourly retention checks, and task deletion use cancellable detached work instead of synchronously copying or removing large task data on the main actor.

## Resolved P2 findings

1. **Image orientation** — ImageIO applies JPEG and HEIC orientation metadata before OCR or PDF generation; a regression test verifies rotated dimensions.
2. **Completed-route format state** — after a route is complete, only formats that are valid enabled sources remain selectable.
3. **Website target size** — navigation and language links provide at least a 44 px block-size target without increasing visible density.
4. **Silent PDF page omission** — merge and watermark operations stop with a page-specific error when PDFKit cannot copy or access a page. Rotation and cropping also fail instead of skipping an unreadable requested page. Reordering validates one complete replacement document and uses it directly, removing the redundant second copy pass and its optional page insertion.
5. **Native route-state contrast** — the unselected source and target labels now use the 4.95:1 muted-text token instead of the 1.99:1 border token.
6. **Preview error announcement** — inline preview errors are exposed as one labeled accessibility element and request a high-priority VoiceOver announcement when they appear.
7. **Large input-list rendering** — the input file well uses a `LazyVStack` within the existing outer scroll view, so large batches do not instantiate every file row at once.
8. **Partial and unsafe file selection** — document metadata inspection runs off the main actor; any invalid item rejects the full batch without replacing the current selection, and both the UI and engine reject directories and symbolic links.

## Resolved P3 findings

1. Result saving now presents a compact progress indicator and an explicit cancel action instead of disabling the only save control with no way to stop the copy.
2. Removed unsupported PDF replacement fields from the job model.
3. Updated the native README from the beta-era requirement to Xcode 26.6 or a compatible newer release.
4. Added Open Graph assets, per-page social metadata, App Privacy Required Reason coverage for file timestamps, and synthetic review files.
5. Keychain reload, save, deletion, and failure messages now request VoiceOver announcements; errors use high priority and successful status changes use medium priority.
6. Translation provider labels preserve the official `DeepSeek` and `OpenAI` capitalization in the workbench instead of deriving user-facing brands from lowercase API identifiers.
7. File selection is available only after a complete route is chosen. The file well, drag-and-drop, keyboard and accessibility actions, model guard, and **File → 选择文件…** (`⌘O`) command share the same state; the misleading shared-model `New Window` command is removed.

## Additional reliability hardening

- PDF preview cache checks and rendering now run outside the main actor and propagate task cancellation.
- Preview failures remain visible with a specific message and a retry action instead of silently clearing the preview area.
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
- Keychain read failures disable credential editing until a successful reload. Failed multi-provider saves attempt to roll back every started write, including writes that mutate before throwing, then re-read Keychain and report the actual stored state. Failed deletions use the same reconciliation path, and malformed non-UTF-8 credential data is rejected. Local-only jobs no longer read translation credentials; translation jobs report Keychain access errors before network work.
- Provider keys request Data Protection Keychain storage with `WhenUnlockedThisDeviceOnly`; existing legacy entries migrate without losing the credential, while unsigned development builds retain a tested legacy fallback when the application identity entitlement is unavailable.
- Input copying opens source and destination descriptors without following symbolic links, confirms regular-file status on the opened descriptors, and prechecks the actual source size. It then copies in bounded 1 MiB chunks, enforces the cumulative route limit before every write, detects size changes during transfer, and checks cancellation between chunks. Oversize, changed, failed, or cancelled imports remove the partial destination and every completed copy from the same batch. Text-to-PDF input is capped at 20 MB, while other native routes retain the 250 MB limit; the UI, preflight, streaming copy, and text processor all apply the matching limit before text is loaded.
- Task submission locks route selection, route reset, option controls, file picking, drag-and-drop, and input removal until input validation and copying finish. Matching model guards prevent non-UI calls from changing the route or input list during the same interval.
- Task creation runs structural preflight before writing task data. Empty inputs, mismatched extensions, invalid file sizes, overflowing or oversized totals, invalid merge counts, unregistered routes, and malformed PDF edit, translation, or OCR options cannot create a task directory; persisted metadata stores only the matching canonical capability route. Preflight, the processor, and restart recovery share the same route-option validation rules.
- PDF edit validation caps page-selection text at 4,096 characters, crop-box text at 256 characters, and watermark text at 512 characters. Crop coordinates must be finite, preventing unbounded option parsing, oversized repeated annotations, and infinite PDF page bounds.
- Image-to-PDF conversion caps decoded images at 3,508 pixels, while OCR and image-to-Markdown cap them at 2,400 pixels; EXIF orientation remains applied during thumbnail decoding.
- OCR plain-text output and Markdown extraction write recognized pages incrementally instead of retaining the full document text in memory. Multi-page and multi-document regression tests preserve page boundaries, order, and Markdown separators.
- Single-document PDF editing mutates the processor-owned in-memory document instead of cloning every page before applying an operation. Merge retains independent per-page copies, source PDFs remain unchanged on disk, and delete, rotate, reorder, crop, and watermark loops propagate cancellation between pages.

## Verification

| Check | Result |
| --- | --- |
| Swift package tests with Xcode 26.6 | 112/112 passed, including strict concurrency with warnings as errors |
| Xcode scheme tests with Xcode 26.6 | 112/112 passed |
| Xcode static analyzer with Xcode 26.6 | Passed with no code findings |
| Unsigned Release archive with Xcode 26.6 | Passed; 5.4 MB universal `arm64` + `x86_64` app |
| Archive dependency inspection | Apple system frameworks only; no Python, Homebrew, Chromium, Tesseract, OCRmyPDF, PyMuPDF, or BabelDOC payload |
| Archive resources | AppIcon and `PrivacyInfo.xcprivacy` present; privacy manifest passes `plutil` |
| Real native UI smoke test | PDF editing, two-file merge, local Vision OCR, translation disclosure, missing-key error, Keychain settings, visible preview failure, and successful preview retry verified |
| OCR output inspection | Generated one-page searchable PDF with an extractable text layer |
| Quit/lifecycle check | App exits and leaves no process or listener on TCP port 8765 |
| Support website | Current ESLint, production build, and 5/5 rendered HTML tests passed. Earlier desktop and 390 px browser checks had no horizontal overflow or console errors; the current Playwright CLI visual rerun was unavailable because its configured Chrome runtime is not installed. |
| Xcode 26.6 production verification | License accepted; tests, analysis, archive, dependency inspection, and launch smoke test passed |
| Code signing | Blocked; this Mac reports zero valid code-signing identities |

Additional reliability coverage verifies that failed result saves preserve the existing destination, saving rejects the submitted original plus symbolic and hard links to it after later input-selection changes while allowing unrelated destinations, failed multi-file imports remove incomplete task directories, mixed selections are rejected atomically, symbolic links are rejected at selection, copy, recovery, preview, and export time, and copied-byte counts enforce the route-specific upload limit. Result-export regressions verify that cancellation removes the sibling temporary copy, same-size source mutation is detected, symbolic-link sources are rejected, and the existing destination remains unchanged in every failure case. Model-level save regressions verify visible busy state, duplicate-save and deletion guards, cancellation without an error or Finder reveal, termination cancellation, state restoration after cancellation, and Finder reveal only after successful download. Dedicated input-transfer regressions cover rejection before creating an oversized destination, cumulative limits across multiple files, a source growing past the limit during transfer, cancellation propagation, and cleanup of partial and completed batch copies. Persisted-state regressions verify that oversized job state is rejected but remains deletable, oversized route metadata becomes a visible deletable failed task, an oversized otherwise-valid completion receipt cannot recover a translation as finished, and retention cleanup uses directory age without reading oversized state. Oversized text is rejected by preflight, import, and the processor before loading, route or input mutations are rejected while task submission is active, and local task metadata omits unrelated user-entered options. Malformed, oversized, and non-finite PDF edit options fail before processing; invalid persisted options and merge counts cannot resume local work; processor-level input-count checks reject PDF translation and single-document edits with anything other than one PDF and merges with fewer than two PDFs; PDF edit regressions verify that the source file remains unchanged and every reordered page remains present in the requested order without redundant whole-document copying; image conversion writes every input page; oversized images are downsampled with their aspect ratio intact; corrupt preview caches are regenerated; preview failures are visible and retryable; and corrupt task metadata becomes deletable failed state. Path-boundary coverage verifies that stored input and result names cannot escape their task directories, symbolic-link task directories are rejected, and preview links are replaced without changing their targets. Persistence fault injection covers running, completion, failure, and cancellation state writes; restart coverage verifies receipt-backed complete-output recovery, rejection of readable partial PDFs without a receipt, local-task resumption, suppression of automatic translation retries, and removal of a dismissed task's restoration reference when the route is reset. Processor fault injection verifies that partial output is deleted after both processing failure and cancellation without removing a completed result needed for recovery, and that missing or unexpectedly located outputs cannot be accepted as successful results. Credential fault injection verifies load-failure write blocking, partial-save rollback, Data Protection Keychain migration, unsigned-build fallback, preflight error classification, no credential access for local jobs, and clear translation failure before network work. Translation coverage verifies the 200-page and 200,000-character pre-request limits, processor-level single-input enforcement, non-persistent session configuration, streamed response cutoff with and without `Content-Length`, `Retry-After` handling, bounded retries after repeated timeouts, cancellation during backoff, and immediate failure for authentication errors without using a real provider key. Cleanup coverage verifies creation-time retention despite conflicting directory timestamps, filesystem-time cleanup for orphaned directories, periodic runtime removal with current-result state clearing, preservation of active work, deletion of failed and cancelled task data, and waiting for cancelled processing and preview work so neither can recreate the task directory. Long-document coverage also verifies the 20,000-character glossary limit, searchable output from multiple text inputs, and clear rejection of damaged PDFs during Markdown extraction. An end-to-end native-engine test covers input import, processing, and result download through the cancellable background transfer path.

## Submission blockers outside the repository

- Activate the individual Apple Developer membership and finish identity verification.
- Register the final unique bundle identifier; `com.transall.mac` remains provisional.
- Create the Mac App Distribution and installer signing assets, validate Data Protection Keychain save/read/delete behavior, and validate a signed archive in Organizer.
- Supply the verified legal seller name, public support email, domain, Paid Apps Agreement, tax, banking, pricing, territories, and DSA declaration.
- Publish the prepared support/privacy site and provide a rate-limited review API key through App Store Connect.
