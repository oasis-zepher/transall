# Transall for macOS

This package is the native SwiftUI edition of Transall. It does not use a `WebView` or a Python sidecar.

Simplified Chinese (`zh-Hans`) is currently the app's only declared bundle localization. The XcodeGen source, generated Xcode project, source `Info.plist`, and rebuilt Release product use the same language metadata.

```text
SwiftUI document workbench
    ├── PDFKit / Core Graphics: PDF operations and rendering
    ├── Vision: local OCR
    ├── Core Text: searchable PDF creation
    └── URLSession: opt-in DeepSeek or OpenAI translation
```

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
| Text, CSV, or JSON to PDF | 20 MB |
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

The circular format router uses semantic SwiftUI type. Accessibility text sizes expand its nodes, allow two-line format labels without shrinking them, and adjust the orbit radius to keep the controls inside the workbench. For routes such as PDF → PDF, the shared node retains both roles visually and reports both roles to assistive technology.

Choose both the source and target formats before adding files. After the route is complete, use the file well or **File → 选择文件…** (`⌘O`); the empty file well can be focused and opened with Return or Space, and the picker is filtered to the selected source format. Incomplete routes do not accept clicks, drops, keyboard activation, accessibility actions, or menu imports.

The input heading uses **FILE** for exactly one selected document and **FILES** for zero or multiple documents. Regression coverage checks 0, 1, and 2 files; the current universal Release build was also verified with one imported PDF.

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

Last verified on 2026-09-01: the pinned XcodeGen 2.46.0 installer passed its SHA-256 and version checks, used distinct private mode-0600 archive files across two concurrent real installations, and left a pre-created legacy literal path untouched. Isolated project generation matched every tracked Xcode project file and `Info.plist`. The standalone metadata validator passed all four release files; verified the exact Debug/Release sandbox capabilities, stable Info.plist source values, no-tracking privacy declarations, Other User Content purpose, and both Required Reason APIs; and produced the expected result for all 36 baseline/mutation fixtures. The repository suite passed 113/113 tests, strict recursive Swift formatting passed with zero findings, 164/164 Swift package tests passed with strict concurrency and warnings as errors, the Xcode Scheme result bundle reported 164/164, and Release analysis passed. An intentional temporary version drift was rejected before compilation. A real unsigned archive without `TRANSALL_PRIVACY_POLICY_URL` failed in the privacy validator; a temporary archive with a public HTTPS test fixture succeeded and retained the expanded URL. The latest universal Release build from 2026-08-28 reported `CFBundleDevelopmentRegion = zh-Hans` with `CFBundleLocalizations = ["zh-Hans"]`. Completion, failure, and cancellation request bounded VoiceOver announcements without moving keyboard focus; queued and running updates remain silent. Settings publishes a distinct announcement event for every non-empty result, so repeated actions with the same outcome are announced separately. Format nodes and the header share one model-level route lock, including visible and accessible reasons during import, task creation, result saving, and processing. Malformed or oversized provider keys fail locally before any document request starts. Credential rows keep confirmed storage state separate from unsaved draft text, and the save action remains disabled until a draft changes. Restored results cannot replace existing files, duplicate preview requests cannot change the active request's state, and preview, result-save policy, and confirmed deletion cannot cross from an older task into its replacement.

A real native interaction pass verified route selection, PDF import, a two-page PDF edit result, preview generation, and the updated accessibility tree. Decorative document symbols no longer add generic or incorrect VoiceOver announcements before the task-specific text.

The repository workflow in [`../../.github/workflows/tests.yml`](../../.github/workflows/tests.yml) installs the SHA-256-pinned XcodeGen release, rejects generated-project drift, and invokes the same executable metadata validator, 36-fixture mutation gate, and native formatting command before compilation. It also runs the 113-test repository suite, Xcode Release analysis, and the support site's dependency audit, lint, production build, and rendered pages. The current browser and native commands pass locally. Eight workflow-source regressions protect XcodeGen installation, secure temporary archive handling, project comparison, metadata semantics, and submission-archive privacy configuration. The new jobs have not run on GitHub yet because the commits have not been pushed.

Some Command Line Tools installations do not ship the XCTest module or Swift Testing runtime in the paths expected by SwiftPM. The package itself still builds with `swift build`; a complete Xcode installation provides the normal test and signing runtime.

## App packaging

The committed Xcode project includes App Sandbox entitlements, the privacy manifest, and the complete AppIcon set. A store upload still needs:

1. A unique bundle identifier owned by the publisher.
2. An Apple Developer team and Mac App Distribution signing assets.
3. App Store Connect metadata, screenshots, public support URL, privacy-policy URL, and the same URL in the Release archive's `TRANSALL_PRIVACY_POLICY_URL` setting.

The broader FastAPI/browser edition remains in the repository, but none of its Python dependencies are linked or copied into the native app bundle.
