# PDFium

Local PDF content editing engine, Chromium build 8046, statically linked.
Universal arm64/x86_64 prebuilt archive and matching public headers:
https://github.com/paulocoutinhox/pdfium-lib/releases/tag/8046d

`macos.zip` SHA-256:
`1f718f8aeee279c8021de5d61ea9a604613fbfa2d83d79172d9086d711778554`

The archive's `release/lib/libpdfium.a` and `release/include` are copied
unmodified. The upstream build workflow is `.github/workflows/macos.yml` at
that tag. PDFium source: https://pdfium.googlesource.com/pdfium/.

Xcode and SwiftPM link this static library plus libc++. No engine dylib,
external helper, runtime download or relaxed library-validation entitlement
is required. All PDFium calls are serialized on the main actor; documents
own their source byte storage. Transall does not initialize JavaScript or
execute PDF document actions.

BSD and third-party notices are included in `Resources/PDFium-Licenses`
and copied into the app bundle. This includes the PDFium license, bundled
component notices and the build distributor's MIT notice.
