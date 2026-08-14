# Transall for macOS

This package is the native SwiftUI client for Transall. It does not use a `WebView`.

```text
SwiftUI interface
    ↕ URLSession on 127.0.0.1:8765
FastAPI sidecar
    ↕
existing conversion, PDF, OCR, and translation engines
```

## Development

Requirements:

- macOS 14 or newer
- Swift 6 toolchain
- `uv`
- the repository's `requirements.lock`

Run from this directory so the app can discover the repository root:

```bash
swift build
swift run TransallMac
```

The client first connects to an existing service at `127.0.0.1:8765`. If none is running, it starts `app.native_entry` with `uv`. These environment variables override discovery:

| Variable | Purpose |
| --- | --- |
| `TRANSALL_BACKEND_URL` | Local backend URL |
| `TRANSALL_PROJECT_ROOT` | Repository root containing `app/main.py` |
| `TRANSALL_UV_EXECUTABLE` | Absolute path to `uv` |

Local App data is stored in `~/Library/Application Support/Transall/Data` when the SwiftUI app owns the backend process.

## Tests

```bash
swift test
```

Some Command Line Tools installations do not ship the XCTest module or Swift Testing runtime in the paths expected by SwiftPM. The package itself still builds with `swift build`; a complete Xcode installation provides the normal test and signing runtime.

## App packaging

`Support/Info.plist` contains the bundle metadata and allows localhost networking. A distributable build still needs:

1. A complete Xcode installation.
2. The Python engine packaged as the bundle auxiliary executable `transall-backend`.
3. App signing, notarization, and a DMG or ZIP release artifact.

`BackendService` already prefers the bundled `transall-backend`, then falls back to the source-checkout development command.
