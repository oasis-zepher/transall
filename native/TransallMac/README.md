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

Input limits are route-specific so text rendering cannot create an excessive in-memory document:

| Route | Combined input limit |
| --- | ---: |
| Text, CSV, or JSON to PDF | 20 MB |
| Other native routes | 250 MB |

The displayed limit is enforced during file selection and task preflight, rechecked against the copied files, and checked again before text data is loaded for PDF generation.

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
