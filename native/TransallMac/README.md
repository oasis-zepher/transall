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

Run from this directory:

```bash
swift build
swift run TransallMac
```

Local task copies, previews, logs, and results are stored in the app's Application Support container. Task data can be deleted from the result panel and is removed after it becomes more than 24 hours old, either when the app launches or during an hourly retention check while the app remains open. Active processing is never removed by a runtime retention check.

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

Result export uses the same bounded transfer path. It writes to a sibling temporary file, rejects symbolic-link or changing task results, and replaces the selected destination only after the copy is complete. The result panel shows save progress and a cancel action; cancellation or app termination stops the active copy without showing an error or opening Finder. Cancellation or failure removes the temporary copy without changing an existing destination, and conflicting result or route operations stay disabled until saving ends.

Keychain reads, saves, deletion, migration, rollback, and reconciliation run on a serial background actor. Launch diagnostics, Settings, and translation preflight therefore remain responsive if macOS Keychain access is delayed, while Settings publications stay isolated to the main actor. Environment refresh reuses one credential-status snapshot for diagnostics and provider availability, translation startup reads only the selected provider key once, and Settings rejects overlapping save or delete mutations before they reach Keychain.

App startup is idempotent: repeated or overlapping SwiftUI lifecycle callbacks initialize the native engine, credential environment, restored task, and retention cleanup only once after startup succeeds. A failed engine start remains retryable. Cancellation between asynchronous startup stages stops before later state is published or cleanup begins, and a later lifecycle callback can finish initialization.

The circular format router uses semantic SwiftUI type. Accessibility text sizes expand its nodes, allow two-line format labels without shrinking them, and adjust the orbit radius to keep the controls inside the workbench. For routes such as PDF → PDF, the shared node retains both roles visually and reports both roles to assistive technology.

Choose both the source and target formats before adding files. After the route is complete, use the file well or **File → 选择文件…** (`⌘O`); the empty file well can be focused and opened with Return or Space, and the picker is filtered to the selected source format. Incomplete routes do not accept clicks, drops, keyboard activation, accessibility actions, or menu imports.

The input heading uses **FILE** for exactly one selected document and **FILES** for zero or multiple documents. Regression coverage checks 0, 1, and 2 files; the current universal Release build was also verified with one imported PDF.

## Tests

```bash
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

Last verified on 2026-08-27: strict recursive Swift formatting passed with zero findings, 134/134 Swift package tests passed with strict concurrency and warnings as errors, 134/134 Xcode scheme tests passed, Release analysis passed, and the built app reported `CFBundleDevelopmentRegion = zh-Hans` with `CFBundleLocalizations = ["zh-Hans"]`.

The repository workflow in [`../../.github/workflows/tests.yml`](../../.github/workflows/tests.yml) enforces the same native formatting command before compilation. It also checks the release plist, entitlements, privacy manifest, Xcode Release analysis, and the support site's dependency audit, lint, production build, and rendered pages. These commands pass locally. The new jobs have not run on GitHub yet because the commits have not been pushed.

Some Command Line Tools installations do not ship the XCTest module or Swift Testing runtime in the paths expected by SwiftPM. The package itself still builds with `swift build`; a complete Xcode installation provides the normal test and signing runtime.

## App packaging

The committed Xcode project includes App Sandbox entitlements, the privacy manifest, and the complete AppIcon set. A store upload still needs:

1. A unique bundle identifier owned by the publisher.
2. An Apple Developer team and Mac App Distribution signing assets.
3. App Store Connect metadata, screenshots, public support URL, and privacy-policy URL.

The broader FastAPI/browser edition remains in the repository, but none of its Python dependencies are linked or copied into the native app bundle.
