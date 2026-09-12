# Native document workspace — 2026-09-12

The user subsequently selected the large format orbit as the entry layout. See the [orbit follow-up](2026-09-12-native-orbit.md); document inspection and export validation below remain applicable.

## Delivered

The native app now uses five task categories, a task/file sidebar, a central document viewer and a parameter inspector. The default content size is 1240 × 820 with a 760 × 680 minimum. Below 1040 points the task selector moves to the toolbar and the file list becomes a collapsible section above the document.

System semantic colors, system fonts and SF Symbols replace the warm paper palette, rust accent, circular format router and decorative section labels. The user’s system accent is respected; the default resolves to system blue. Native macOS 26 glass button styles and a grouped glass navigation bar are used. Documents and parameter surfaces remain opaque. Reduce Transparency and Increase Contrast use solid controls and stronger boundaries.

Start/cancel/save actions sit at the bottom of the inspector and move into the toolbar when the inspector is hidden. Processing details are collapsed initially. Errors, translation recovery and the text-sharing notice remain visible at the point of use.

Inputs use read-only preview copies; PDFs and images render in the main window. Verified PDF, Markdown and plain-text results have inline previews. PDF results retain original/result/comparison selection, full-document search, page navigation, zoom, equal-page-count synchronization and translation issue inspection. Comparison originals come from submitted task copies. Switching tasks clears drafts while retaining generated job data. Restoring a job restores its route/options/result and retains the new-file-only export protection.

The preview pass also found and corrected an existing OCR rasterization defect: upscaled PDF pages were centered at their original size inside a larger raster. Rendering now composes the page transform with the raster scale explicitly, including quarter-turn rotations.

Browser sources and app-icon changes already present in the checkout were preserved. No publishing or remote CI run was performed for this local redesign.

## Automated validation

Environment: Apple Silicon, macOS 27.0, Xcode 26.6, XcodeGen 2.46.0. Deployment target remains macOS 14.0.

| Check | Result |
|---|---|
| Swift package, complete strict concurrency, warnings as errors | 206 tests in 6 suites passed |
| Xcode Transall scheme tests | 206 tests in 6 suites passed |
| Release static analysis | ANALYZE SUCCEEDED |
| Release build | BUILD SUCCEEDED |
| swift-format strict lint and git diff whitespace | Passed |
| Generated Xcode project consistency | Passed |
| Release metadata declarations | Passed |
| Metadata validator regressions | 36 fixtures passed |

New workbench coverage checks all ten route mappings; executes all nine local routes through import, processing, verified inspection and actual export; validates output format/content and unchanged input bytes; checks task/source resets, operation locks, restoration, atomic incompatible imports, no-follow preview copies, PDF reload/search reset, tamper rejection and OCR content coverage at 0/90/180/270 degrees. Existing tests continue to cover PDF editing/merging, translation variants, provider failure/retry/cancellation, layout recovery, original-file protection, cancelled/failed saves, result integrity and search synchronization. Provider responses are controlled in tests; no live translation request was sent.

Final logs: `/tmp/transall-workspace-swift-tests.log`, `/tmp/transall-workspace-xcode-tests.log`, `/tmp/transall-workspace-analyze.log`, `/tmp/transall-workspace-release-build.log`, `/tmp/transall-workspace-project-check.log`.

Final Xcode result bundle: `native/TransallMac/.build/workspace-validation/Logs/Test/Test-Transall-2026.09.12_19-50-51-+0800.xcresult`.

## Actual App checks

The final Release app was opened, a synthetic PDF was selected through the system open panel using Command-O and a full path, processed, and saved through the system save panel. Restarting the app restored the completed task, original/result selector and new-file-only saving notice.

An isolated review build used the same production views and engine with synthetic inputs and an empty credential store for additional states. Its temporary entry point only selected initial scenarios and export destinations; it is ignored under `.build/workspace-review` and is not part of the shipping app.

| Native UI scenario | Observed result |
|---|---|
| Empty task and source selection | Five tasks accessible; task/source changes clear the draft |
| PDF and image input | Original content renders; PDF page/search controls work |
| Search | `workspace-page-11` located page 11 in the 12-page source |
| PDF processing and comparison | Completion selects the result; original and result display together with linked page navigation |
| File selection after completion | Selecting an input switches back to its preview; “查看处理结果” returns to the result |
| Markdown output | Read-only text renders in dark appearance; export retains all 12 search markers |
| Image/Markdown to PDF and PDF OCR | Actual generated results preview and save successfully |
| Invalid PDF | Clear preview error and failure reason; retry and task changes remain available |
| Running/cancelled OCR | 400-page synthetic scan shows locked parameters and cancel; cancellation restores controls and leaves no partial PDF |
| Compact window | 760 × 680 content size retains task menu, collapsible files and inspector actions |
| System accent | Changing the system accent to green updates selection and primary buttons; restoring multicolor returns to blue |
| Reduce Transparency / Increase Contrast | Real OS settings visibly produce opaque controls and stronger borders |
| Reduce Motion | Task switching works with the real setting enabled |
| Preview cleanup | After leaving review views and quitting, zero `TransallPreview-*` and review `Inspection-*` directories remained |

The original system accent (multicolor), Reduce Transparency (off), Increase Contrast (off) and Reduce Motion (off) were restored after checking. System appearance stayed on Auto; isolated light/dark scenarios used app-local appearance only.

Actual native screenshots were emitted inline in the implementation conversation: light/dark, default blue/green accent, input PDF/image, original/result comparison, text output, compact running/cancelled, failure and accessibility fallback. They are native App captures, not browser mockups. They have not been saved as a separate screenshot archive. Some background-window captures show macOS inactive control colors.

## Export evidence

Synthetic sources and exported examples are in `output/pdf/workspace-redesign/`.

| File | Checked content |
|---|---|
| `exported-edit.pdf` | 12-page edited PDF; first-page raster is pixel-identical to the same renderer’s original raster |
| `exported-markdown.pdf` | Markdown headings and list render legibly |
| `exported-ocr-fixed.pdf` | 12-page searchable PDF; full-size page content restored and rendered inspection passed |
| `exported-extract.md` | 12 ordered page markers and readable source text |
| `exported-release-verified.pdf` | Saved through the final Release app’s native panel; 12 A4 pages |

Source SHA-256 values were unchanged after the final processing/save checks. The failed pre-fix OCR export was removed from the deliverable folder.

## Verification limits

macOS 14–15 and macOS 26 were not available for a separate runtime check; native API availability guards compiled successfully on the current macOS 27 host. Full VoiceOver traversal and all system text-size settings were not manually exercised. The accessibility tree and native labels, keyboard import, operation locks and live display settings were checked. Real provider credentials/network translation were not exercised; their existing controlled integration and recovery tests passed.

## Run

Final local app: `native/TransallMac/.build/workspace-validation/Build/Products/Release/Transall.app`.

This is a locally built app; App Store signing, distribution and remote CI are outside this change.
