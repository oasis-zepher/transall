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
- Xcode 27 or a compatible Swift toolchain

Run from this directory:

```bash
swift build
swift run TransallMac
```

Local task copies, previews, logs, and results are stored in the app's Application Support container. Completed task data can be deleted from the result panel and is removed automatically after 24 hours.

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
