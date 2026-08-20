# Transall for macOS

This package is the native SwiftUI edition of Transall. It does not use a `WebView` or a Python sidecar.

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

While preflight and input copying run, the workbench shows **取消创建**. `AppModel` owns this submission task, keeps the submitted route, files, and options immutable, and cancels it when requested or when the app terminates. Normal cancellation does not show an error or publish a task. Incomplete task data is removed, including the narrow case where backend creation finishes at the same time as cancellation.

Result export uses the same bounded transfer path. It writes to a sibling temporary file, rejects symbolic-link or changing task results, and replaces the selected destination only after the copy is complete. The result panel shows save progress and a cancel action; cancellation or app termination stops the active copy without showing an error or opening Finder. Cancellation or failure removes the temporary copy without changing an existing destination, and conflicting result or route operations stay disabled until saving ends.

Keychain reads, saves, deletion, migration, rollback, and reconciliation run on a serial background actor. Launch diagnostics, Settings, and translation preflight therefore remain responsive if macOS Keychain access is delayed, while Settings publications stay isolated to the main actor.

The circular format router uses semantic SwiftUI type. Accessibility text sizes expand its nodes, allow two-line format labels without shrinking them, and adjust the orbit radius to keep the controls inside the workbench.

Choose both the source and target formats before adding files. After the route is complete, use the file well or **File → 选择文件…** (`⌘O`); the picker is filtered to the selected source format. Incomplete routes do not accept clicks, drops, accessibility actions, or menu imports.

## Tests

```bash
swift test
```

Some Command Line Tools installations do not ship the XCTest module or Swift Testing runtime in the paths expected by SwiftPM. The package itself still builds with `swift build`; a complete Xcode installation provides the normal test and signing runtime.

## App packaging

The committed Xcode project includes App Sandbox entitlements, the privacy manifest, and the complete AppIcon set. A store upload still needs:

1. A unique bundle identifier owned by the publisher.
2. An Apple Developer team and Mac App Distribution signing assets.
3. App Store Connect metadata, screenshots, public support URL, and privacy-policy URL.

The broader FastAPI/browser edition remains in the repository, but none of its Python dependencies are linked or copied into the native app bundle.
