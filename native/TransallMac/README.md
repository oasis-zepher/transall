# Transall for macOS

This package is the native SwiftUI edition of Transall. The interface remains SwiftUI. HTML/Markdown printing uses an offscreen system WebKit view; no Python sidecar or browser runtime is bundled. Office conversion uses an independently installed LibreOffice.

Simplified Chinese (`zh-Hans`) is currently the app's only declared bundle localization. The XcodeGen source, generated Xcode project, source `Info.plist`, and rebuilt Release product use the same language metadata.

The interface follows the system's light or dark appearance. On macOS 26 and later, navigation and controls use native Liquid Glass button styles, effect containers and the system toolbar. Document and form surfaces remain opaque for reading. macOS 14/15 retain opaque controls; custom controls also use opaque backgrounds and stronger boundaries when Reduce Transparency or Increase Contrast is enabled, and custom motion responds to Reduce Motion. A large format orbit is the main entry, following the browser version. Drag the rounded glass modules into the source and target chambers of one native Liquid Glass hourglass, in either order, then add files. Selected modules leave the outer ring, whose remaining modules slide along the circle to equal angular spacing. Within 64 points of a compatible chamber, including replacements, the dragged module morphs into that half of the hourglass over 780 ms with slight attraction. An incompatible chamber contracts its width to 85%, with unscaled labels and no attraction; leaving restores the shape over 280 ms. Every module uses a vertical compatibility gradient: upper half for source, lower half for output, native white/near-black when supported and the same unfilled glass as the hourglass when unsupported (a shared system control fill in opaque mode). Help and accessibility values name both roles; Differentiate Without Color adds corresponding top/bottom marks. Reserve the active upper/lower extrusion corridor by smoothly rotating the evenly spaced outer ring just far enough to clear it, including an 8-point margin; hold that gap until the bulb finishes retracting or departing. Approaching from the waist ramps feedback through the chamber instead of reaching full strength at the rectangular hit edge. Incoming morph and attached preparation share a 780 ms ease-in-out approach, with 640 ms mouse-up settlement and 280 ms retraction; retain the original 22% attraction. Gray modules remain draggable, while click, keyboard and accessibility assignment still reject invalid routes. Invalid drops return without changing the draft. The waist rejects drops. Hover highlighting uses the complete 84-point visual half, independently of the 68-point hit region, so its top matches the morphed contour. The waist has flip on its left and clear on its right, at the same height. One animated presentation synchronizes shape and magnetic position, with the original gentle attraction during dragging and exact placement only after release, and retains continuity through release and waits for ring redistribution before handing back to the stationary module; chamber direction morphs through a neutral shape without an instantaneous mirror. Clear returns the selected modules to the ring. A manually returned module is inserted between the two neighbors chosen by its drop point; replaced modules bulge through their chamber’s outer lip, remain attached by a narrowing glass neck, and separate before curving into the ring (source upward, target downward). A compatible approaching replacement already pushes the old module outward while it remains attached; retreat pulls it back without changing the draft. Mouse-up continues the same presentation into separation instead of starting a new animation. The full 960 ms extrusion reveals the format name after the small-bud stage and restores the normal module and role gradient on the way to the ring. Circular order is retained when visiting the document workspace. The flip button validates the reverse route before and after a 420 ms rotation, keeps text upright, and commits once. Successful flips clear the draft and preview, reset parameters and preserve stored jobs; unsupported flips explain their disabled state. Reduce Motion updates the selection without spatial animation. The empty central slot retains a PDF-to-PDF shortcut. Occupied slots support compatible swaps, moves and removal. Clicks, keyboard activation, context menus and VoiceOver remain available. Only supported native routes can be selected; PDF to PDF opens editing/merging. Importing switches to the document workspace, whose toolbar can return to the orbit while retaining the draft. The main window previews PDF/image inputs and verified PDF/text results; parameters live in the inspector and processing details are collapsed by default. System semantic colors and the user's control accent replace the former warm paper palette. See the [native workspace implementation and verification record](../../docs/reviews/2026-09-12-native-workspace.md) for export and accessibility evidence, and the [large-orbit follow-up](../../docs/reviews/2026-09-12-native-orbit.md) for the orbit history, and the [hourglass verification record](../../docs/reviews/2026-09-12-native-hourglass.md) for the current selector and runtime limits.

```text
SwiftUI document workbench
    ├── PDFKit / Core Graphics: PDF operations and rendering
    ├── Vision: local OCR
    ├── Core Text / offscreen WebKit: searchable PDF creation
    ├── Optional LibreOffice: Office PDF conversion and structured extraction
    └── URLSession: opt-in DeepSeek or OpenAI translation
```

PDF translation offers three outputs: translated text, bilingual text, and a layout-preserving PDF. The layout-preserving path extracts native PDF text, uses local Vision OCR for text embedded in images, removes duplicate regions, and sends only the extracted text to the selected provider. Stable region identifiers keep responses mapped to their source positions; omitted items are retried individually, while duplicate, unexpected, blank, or abnormally long responses stop result generation. The output retains page count, rotation, crop and other page boxes, and annotations including internal page links. A high-resolution JPEG background removes hidden source-text objects; searchable translated text is drawn over it. The background is no longer editable vector content. Duplicate text is removed only at overlapping positions. Fitting requires at least 8 pt and 75% of the capped preferred size; if a region cannot fit, no partial result is returned. These thresholds reject known unreadable outputs but do not establish translation accuracy or universal readability.

The native edition exposes 18 conversion routes. Word (`doc`, `docx`), PowerPoint (`ppt`, `pptx`) and Excel (`xls`, `xlsx`) convert to PDF or Markdown through local LibreOffice. Each invocation gets private input copies and a separate profile with macro execution disabled; cancellation and a 120-second timeout stop the child and remove intermediate files. PDF batches merge in input order; Markdown preserves document/slide/sheet order, headings, lists and tables. Extraction is structural, not a layout-preserving editable Office export. Unsupported oversized tables fail explicitly instead of truncating columns. LibreOffice is detected in `/Applications` or the user's `Applications`; its presence appears in Settings and a missing installation is explained before processing. Nothing is installed automatically. In a signed sandboxed build, Settings offers one-time activation of a fixed conversion script in the app-specific Application Scripts folder, using a native folder grant. The app verifies the script before running it through NSUserUnixTask; no sandbox entitlements are relaxed. The helper handles timeout/cancellation and exits without opening Office windows. Development runs outside the sandbox can invoke LibreOffice directly.

HTML/Markdown → PDF uses system print pagination with inline styles, tables and embedded data images. Scripts and external resource loads are blocked. Relative/remote Markdown images remain alt-text placeholders, as they are not imported with the document. HTML → Markdown preserves headings, lists, links and tables. Data → Markdown supports TXT, CSV/TSV, JSON, XML and YAML; ZIP/EPUB extraction is not included. No rendering controls are added to the task panel.

PDF edit's existing advanced options now include exact, case-sensitive single-line find/replace. Only matching pages are redrawn at up to 3× resolution (3508-pixel maximum dimension), replacing the matched regions with a white background and fitted text. Old text is removed; unaffected text on those pages is reattached as a searchable invisible layer. Other pages remain untouched. Modified pages preserve page boxes and rotation but flatten interactive annotations and vector content. Replacement that cannot fit at 8 pt or a cross-line match fails explicitly. New optional job-option fields preserve decoding of existing tasks.

Completed layout translations are saved before PDF rendering. If layout fails, **查看问题区域…** opens the submitted original with overflow regions highlighted and the corresponding source and translation. **生成纯译文 PDF** reuses the complete cached translation locally, without reading a provider key or making another translation request. Each original page starts on a new output page; text can flow onto additional pages. The cache survives restart within the existing 24-hour task retention and is deleted with the task. It does not resume incomplete network batches. Cache reads are bounded to 32 MiB, reject linked or changing files, verify a content digest and the full submitted-source SHA-256, and bind provider, languages and glossary. No credentials or original-file paths are stored in the cache.

Completed PDFs have a **检查与对照…** viewer with zoom, page-number entry, previous/next page controls and per-document text search, independent of the first-eight-page thumbnails. Search shows match counts and previous/next navigation, stops at 2,000 matches or 8 seconds, and can be cleared or replaced. When the task has one PDF input, comparison uses the private copy captured at submission. Same-page and scroll-position linking is optional and disabled when the page counts differ; it does not infer semantic paragraph alignment. Inspection validates completed results and removes its temporary copies on close. Source and target translation languages are visible outside advanced settings. Visual page selection and crop editing remain future work.

## Development

Requirements:

- macOS 14 or newer
- Xcode 26.6 or a compatible newer release toolchain
- XcodeGen 2.46.0 when regenerating or verifying the committed Xcode project; CI installs the pinned official archive automatically

Run from this directory:

```bash
swift build
swift run TransallMac
```

Local task copies, previews, logs, and results are stored in the app's Application Support container. Task data can be deleted from the result panel and is removed after it becomes more than 24 hours old, either when the app launches or during an hourly retention check while the app remains open. Manual deletion is unavailable while a replacement task is being created. Its confirmation retains the displayed task identifier, closes if the current task changes, and the model rejects stale identifiers before deleting local data. Active processing is never removed by a runtime retention check.

Persisted task JSON is bounded before writing and decoding: 1 MiB for job state, 128 KiB for route metadata, and 16 KiB for completion receipts. Recovery and retention scans read these files through no-follow regular-file descriptors and reject oversized or changing state without loading it unboundedly.

Input limits are route-specific so text rendering cannot create an excessive in-memory document:

| Route | Combined input limit |
| --- | ---: |
| Text / Markdown / HTML to PDF, HTML / data to Markdown | 20 MB |
| Other native routes | 250 MB |

The displayed limit is enforced during file selection and task preflight, checked again from the opened source file, and enforced while copying in 1 MiB chunks. A source that grows past the limit, a cancellation, or a copy error removes the partial batch before task processing starts. Text data is checked once more before PDF generation loads it.

Every task is also limited to 256 input files. Exact duplicate URLs are removed before metadata inspection, and the workbench stops accepting additional selections at capacity. Preflight, file copying, persisted metadata, and restart recovery enforce the same limit for non-UI and restored tasks.

`AppModel` owns file metadata inspection instead of leaving it in an unreferenced view task. The workbench shows **取消读取** while inspection runs; explicit cancellation or app termination stops the operation silently, preserves the current file list, and prevents overlapping imports.

While preflight and input copying run, the workbench shows **取消创建**. `AppModel` owns this submission task, keeps the submitted route, files, and options immutable, and cancels it when requested or when the app terminates. Normal cancellation does not show an error or publish a task. Incomplete task data is removed, including the narrow case where backend creation finishes at the same time as cancellation.

After task creation, queued and running jobs keep the visible task draft locked to the processor's immutable snapshot. File selection, removal, drag-and-drop, menu, keyboard, accessibility, OCR, translation, and PDF-edit controls remain unavailable until the job completes or is cancelled. Direct model imports and removals are rejected in the same state, and the file well reports the lock reason.

Preview and export recheck the completed task's bounded, no-follow receipt before using its result. Preview verifies the name, size, structural validity, and SHA-256 sample fingerprint before and after generation, removing the cache if either check fails. Export uses the same receipt and hashes the bytes read from the opened source while copying, so a replacement or mid-copy change cannot reach the selected destination.

When asynchronous creation replaces the current task, the model clears preview pages, errors, and loading state again at that exact task-identity boundary. An older task's preview therefore cannot remain visible under the new task even if it completed during preflight or input copying.

Preview generation accepts only one active model request. Duplicate manual, automatic, or non-UI refreshes return before reaching the engine and cannot clear pages, publish a false failure, or end the active request's loading state early.

Result export uses the same bounded transfer path. It writes to a sibling temporary file, rejects symbolic-link or changing task results, and replaces the selected destination only after the copy is complete. Result saving cannot start while a replacement task is being created. An accepted save captures the displayed task's original-document snapshot and replacement policy before destination selection and asynchronous export, so those rules cannot change when a new task becomes current. Current-session tasks reject their submitted originals and links. Restored tasks do not persist original-file identities or security-scoped access, so they can save only to a new destination; the final install uses an atomic exclusive rename and cannot replace a file created during copying. The result panel shows this restriction, save progress, and a cancel action. Cancellation or app termination stops the active copy without showing an error or opening Finder. Cancellation, integrity failure, a late destination, or another copy error removes the temporary copy without changing an existing destination, and conflicting result or route operations stay disabled until saving ends.

Keychain reads, saves, deletion, migration, rollback, and reconciliation run on a serial background actor. Launch diagnostics, Settings, and translation preflight therefore remain responsive if macOS Keychain access is delayed, while Settings publications stay isolated to the main actor. Environment refresh reuses one credential-status snapshot for diagnostics and provider availability, translation startup reads only the selected provider key once, and Settings rejects overlapping save or delete mutations before they reach Keychain. Provider rows derive confirmed configuration and deletion availability from the reconciled Keychain snapshot, while valid pending edits, invalid drafts, and malformed stored values have separate visible and VoiceOver states. The primary save action remains disabled until at least one draft differs from the confirmed snapshot. A shared credential policy allows at most 4,096 UTF-8 bytes and rejects line breaks or control characters before production Keychain writes, preflight, processing, and request sending. Invalid Settings edits preserve existing stored values and produce a high-priority VoiceOver announcement.

Translation requests reject every HTTP redirect before URLSession follows it. The redirect target receives neither the API Key nor document text, the network session is stopped, and the task reports a specific non-retryable privacy error.

Settings includes Transall's own privacy-policy entry alongside the local-data explanation. The destination expands from `TRANSALL_PRIVACY_POLICY_URL` into `TransallPrivacyPolicyURL` in the built app. Development builds show an explicit unconfigured state. Release archives fail before completion unless the value is a public HTTPS URL with a valid hostname and no embedded credentials; the final address must be the published support site's `/privacy` URL.

Successful provider responses must contain at least one non-whitespace translation character. A response made only of spaces, tabs, or line breaks fails before it can produce a visually blank PDF result.

App startup is idempotent: repeated or overlapping SwiftUI lifecycle callbacks initialize the native engine, credential environment, restored task, and retention cleanup only once after startup succeeds. A failed engine start remains retryable. Cancellation between asynchronous startup stages stops before later state is published or cleanup begins, and a later lifecycle callback can finish initialization.

The format router uses system typography and SF Symbols. Each chamber has an independent accessibility label and removal action. PDF → PDF shows the format in both chambers; unavailable modules expose their status and enforce the same model validation through every selection action.

Choose both the source and target formats before adding files. After the route is complete, use the file well or **File → 选择文件…** (`⌘O`); the empty file well can be focused and opened with Return or Space, and the picker is filtered to the selected source format. Incomplete routes do not accept clicks, drops, keyboard activation, accessibility actions, or menu imports.

The document workspace shows the current files with native labels and retains the original/result switch and read-only comparison.

PDF crop input is validated before task creation and again before processing. It must contain exactly four individually valid numbers; entered endpoints and the derived width and height must all be finite, ordered, and positive. The requested rectangle must fit every selected page, and the processor verifies the bounds PDFKit actually applied before reporting success.

## Tests

```bash
scripts/verify_xcodegen_project.sh

scripts/validate_release_metadata.sh

xcrun swift-format lint \
  --strict \
  --recursive \
  --parallel \
  Sources Tests

swift test \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors

xcodebuild \
  -project Transall.xcodeproj \
  -scheme Transall \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  test
```

Before creating the submission archive, set the Release build setting `TRANSALL_PRIVACY_POLICY_URL` to the exact published privacy-policy URL. The generated archive build phase runs `scripts/validate_archive_privacy_policy.sh` against the built `Info.plist`; missing, unexpanded, non-HTTPS, local, reserved, numeric, malformed-host, and invalid-port values fail the archive.

Current verification (2026-09-12): the native workspace, orbit and hourglass update passed 222 strict SwiftPM and Xcode tests, Release analysis/build, formatting, generated-project consistency and 36 release-metadata fixtures. The final Release app was used to import, process, save and restore a synthetic PDF; additional native states and live accessibility settings were checked. See the [workspace verification record](../../docs/reviews/2026-09-12-native-workspace.md) for evidence and runtime limits. The hourglass follow-up includes real light/dark, minimum-window, accent and accessibility screenshots. Pointer dragging still returns `noWindowsAvailable`; actual proximity morphing, return motion and continuous animation smoothness remain unverified. These are local results. The [earlier recovery report](../../docs/reviews/2026-09-05-recovery-inspection.md) and [earlier Liquid Glass report](../../docs/reviews/2026-09-05-liquid-glass.md) retain the historical validation record.

Historical verification through 2026-09-02 follows. Counts and release observations below describe that earlier evidence: The pinned XcodeGen 2.46.0 installer evidence from 2026-09-01 passed its SHA-256 and version checks, used distinct private mode-0600 archive files across two concurrent real installations, and left a pre-created legacy literal path untouched. Isolated project generation matched every tracked Xcode project file and `Info.plist`. The standalone metadata validator passed all four release files; verified the exact Debug/Release sandbox capabilities, stable Info.plist release values, no-tracking privacy declarations, Other User Content purpose, and both Required Reason APIs; and produced the expected result for all 36 baseline/mutation fixtures. The repository suite passed 121/121 tests, the browser and CI Python graphs were fully pinned with SHA-256, every external Action used an official full release commit, checkout credentials were discarded before builds, strict recursive Swift formatting passed with zero findings, 169/169 Swift package tests passed with strict concurrency and warnings as errors, the Xcode Scheme result bundle reported 169/169, and Release analysis passed. An intentional temporary version drift was rejected before compilation. A real unsigned archive without `TRANSALL_PRIVACY_POLICY_URL` failed in the privacy validator; a temporary archive with a public HTTPS test fixture succeeded and retained the expanded URL. The latest universal Release build from 2026-08-28 reported `CFBundleDevelopmentRegion = zh-Hans` with `CFBundleLocalizations = ["zh-Hans"]`. Completion, failure, and cancellation request bounded VoiceOver announcements without moving keyboard focus; queued and running updates remain silent. Settings publishes a distinct announcement event for every non-empty result, so repeated actions with the same outcome are announced separately. Format nodes and the header share one model-level route lock, including visible and accessible reasons during import, task creation, result saving, and processing. Malformed or oversized provider keys fail locally before any document request starts. Credential rows keep confirmed storage state separate from unsaved draft text, and the save action remains disabled until a draft changes. Restored results cannot replace existing files, duplicate preview requests cannot change the active request's state, and preview, result-save policy, and confirmed deletion cannot cross from an older task into its replacement.

A real native interaction pass verified route selection, PDF import, a two-page PDF edit result, preview generation, and the updated accessibility tree. Decorative document symbols no longer add generic or incorrect VoiceOver announcements before the task-specific text.

The repository workflow in [`../../.github/workflows/tests.yml`](../../.github/workflows/tests.yml) pins every external Action to an official full release commit, discards checkout credentials before later commands, installs the SHA-256-pinned XcodeGen release, rejects generated-project drift, and invokes the same executable metadata validator, 36-fixture mutation gate, and native formatting command before compilation. It also installs the complete browser CI graph from a strict SHA-256 lock, runs the repository test suite and OSV audit without dependency re-resolution, performs Xcode Release analysis, and checks the support site's dependency audit, lint, production build, and rendered pages. Weekly Dependabot updates track the immutable Action pins. The current browser and native commands pass locally. Eleven workflow-source regressions and five dependency-lock regressions protect Action references, checkout token lifetime, XcodeGen installation, secure temporary archive handling, project comparison, metadata semantics, dependency reproducibility, and submission-archive privacy configuration. The commits did reach GitHub. The September 2 tests run passed native checks but failed Python Bandit and the support-site dependency audit. The September 5 fixes enforce shell-free subprocess arguments and update the affected dependency lock; remote verification is tracked in the linked fix report.

Some Command Line Tools installations do not ship the XCTest module or Swift Testing runtime in the paths expected by SwiftPM. The package itself still builds with `swift build`; a complete Xcode installation provides the normal test and signing runtime.

## App packaging

The committed Xcode project includes App Sandbox entitlements, the privacy manifest, and the complete AppIcon set. A store upload still needs:

1. A unique bundle identifier owned by the publisher.
2. An Apple Developer team and Mac App Distribution signing assets.
3. App Store Connect metadata, screenshots, public support URL, privacy-policy URL, and the same URL in the Release archive's `TRANSALL_PRIVACY_POLICY_URL` setting.

The broader FastAPI/browser edition remains in the repository, but none of its Python dependencies are linked or copied into the native app bundle.
