# Transall release quality audit

Audit date: 2026-08-14
Quality bar: App Store-ready version 1.0
Surfaces: native SwiftUI app and local support/privacy website

## Result

All P1, P2, and P3 product-quality findings from the baseline audit are resolved. Xcode 26.6 production-toolchain verification also passes. The remaining work is account-holder work: activate the individual Apple Developer membership, choose and register the final bundle identifier, create signing assets, publish the support site, and complete App Store Connect commercial information.

## Health score

| # | Dimension | Baseline | Final | Evidence |
| --- | --- | ---: | ---: | --- |
| 1 | Accessibility | 3/4 | 4/4 | Support-site and native state text reach WCAG AA contrast; navigation targets are at least 44 px, and native controls expose labels, values, focus, reduced-motion behavior, and preview-error announcements. |
| 2 | Performance | 2/4 | 4/4 | OCR and image-to-PDF conversion process one raster page at a time; scanned-PDF routes reuse one raster document handle per input, and large file transfers, PDF previews, startup cleanup, and task deletion run outside the main actor. |
| 3 | Responsive design | 3/4 | 4/4 | Native layout changes at 1040 pt, the website reflows at 820 px, and compact website targets meet the release size baseline. |
| 4 | Theming | 4/4 | 4/4 | Both surfaces retain the quiet, light-first document-workbench palette and centralized color tokens. |
| 5 | Anti-patterns | 4/4 | 4/4 | The product keeps its specific document-workbench identity without generic dashboards, decorative gradients, or unrelated cards. |
| **Total** |  | **16/20** | **20/20** | **Internal product-quality findings resolved; external submission prerequisites remain.** |

## Resolved P1 findings

1. **OCR memory growth** — `NativeDocumentProcessor` now handles PDF pages sequentially, releases each raster image after recognition, and writes searchable pages incrementally.
2. **Ambiguous multiple-file routes** — preflight requires exactly one input for PDF translation and single-document PDF editing; merge mode still accepts multiple PDFs.
3. **Unsafe overwrite saving** — result saving copies to a sibling temporary file and uses atomic replacement, preserving an existing destination if the new copy fails.
4. **Website contrast** — the muted text token now meets WCAG AA for its rendered small-text usage.
5. **Large-file UI blocking** — input imports, result saves, startup cleanup, and task deletion use cancellable detached work instead of synchronously copying or removing up to 250 MB on the main actor.

## Resolved P2 findings

1. **Image orientation** — ImageIO applies JPEG and HEIC orientation metadata before OCR or PDF generation; a regression test verifies rotated dimensions.
2. **Completed-route format state** — after a route is complete, only formats that are valid enabled sources remain selectable.
3. **Website target size** — navigation and language links provide at least a 44 px block-size target without increasing visible density.
4. **Silent PDF page omission** — merge, reorder, and watermark operations now stop with a page-specific error when PDFKit cannot copy a page.
5. **Native route-state contrast** — the unselected source and target labels now use the 4.95:1 muted-text token instead of the 1.99:1 border token.
6. **Preview error announcement** — inline preview errors are exposed as one labeled accessibility element and request a high-priority VoiceOver announcement when they appear.

## Resolved P3 findings

1. Removed the unused `AppModel.isImporting` state.
2. Removed unsupported PDF replacement fields from the job model.
3. Updated the native README from the beta-era requirement to Xcode 26.6 or a compatible newer release.
4. Added Open Graph assets, per-page social metadata, App Privacy Required Reason coverage for file timestamps, and synthetic review files.

## Additional reliability hardening

- PDF preview cache checks and rendering now run outside the main actor and propagate task cancellation.
- Preview failures remain visible with a specific message and a retry action instead of silently clearing the preview area.
- Preview results are applied only to the job that requested them, preventing an older task from overwriting a newer task's state.
- Startup removes only task directories older than 24 hours on a utility-priority task; manual deletion exposes a busy state and blocks conflicting result operations until removal finishes.

## Verification

| Check | Result |
| --- | --- |
| Swift package tests with Xcode 26.6 | 27/27 passed, including strict concurrency with warnings as errors |
| Xcode scheme tests with Xcode 26.6 | 27/27 passed |
| Xcode static analyzer with Xcode 26.6 | Passed with no code findings |
| Unsigned Release archive with Xcode 26.6 | Passed; universal `arm64` + `x86_64` executable |
| Archive dependency inspection | Apple system frameworks only; no Python, Homebrew, Chromium, Tesseract, OCRmyPDF, PyMuPDF, or BabelDOC payload |
| Archive resources | AppIcon and `PrivacyInfo.xcprivacy` present; privacy manifest passes `plutil` |
| Real native UI smoke test | PDF editing, two-file merge, local Vision OCR, translation disclosure, missing-key error, Keychain settings, visible preview failure, and successful preview retry verified |
| OCR output inspection | Generated one-page searchable PDF with an extractable text layer |
| Quit/lifecycle check | App exits and leaves no process or listener on TCP port 8765 |
| Support website | ESLint passed; production build passed; 4/4 rendered HTML tests passed |
| Xcode 26.6 production verification | License accepted; tests, analysis, archive, dependency inspection, and launch smoke test passed |
| Code signing | Blocked; this Mac reports zero valid code-signing identities |

Additional reliability coverage verifies that failed result saves preserve the existing destination, failed multi-file imports remove incomplete task directories, image conversion writes every input page, unknown translation providers are rejected before processing, corrupt preview caches are regenerated, preview failures are visible and retryable, and corrupt task metadata does not prevent local deletion. Cleanup coverage verifies that startup removes expired directories without touching recent jobs and that manual deletion clears only the matching result state. Long-document coverage also verifies the 20,000-character glossary limit, searchable output from multiple text inputs, and clear rejection of damaged PDFs during Markdown extraction. An end-to-end native-engine test covers input import, processing, and result download through the cancellable background transfer path.

## Submission blockers outside the repository

- Activate the individual Apple Developer membership and finish identity verification.
- Register the final unique bundle identifier; `com.transall.mac` remains provisional.
- Create the Mac App Distribution and installer signing assets and validate a signed archive in Organizer.
- Supply the verified legal seller name, public support email, domain, Paid Apps Agreement, tax, banking, pricing, territories, and DSA declaration.
- Publish the prepared support/privacy site and provide a rate-limited review API key through App Store Connect.
