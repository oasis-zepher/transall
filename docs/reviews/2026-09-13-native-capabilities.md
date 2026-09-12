# Native capability expansion — 2026-09-13

The existing five task categories, hourglass interaction, inspector, job store and verified export workflow remain in place. The native route count increases from 10 to 18. Browser files and icon changes were not modified by this work.

| Capability | Implementation |
| --- | --- |
| Word, PPT, Excel → PDF | Optional locally installed LibreOffice; legacy and modern extensions; ordered PDF batch merging |
| Word, PPT, Excel → Markdown | LibreOffice flat OpenDocument export followed by bounded native extraction of the document body, headings, lists, slides, sheets and tables |
| HTML / data → Markdown | Offline HTML structure extraction; quoted CSV/TSV tables and fenced JSON/XML/YAML/text |
| HTML / Markdown → PDF | Offscreen system WebKit and native print pagination; inline CSS, tables and embedded data images |
| PDF find/replace | Optional fields in the existing advanced PDF parameters; removes matched text from the output rather than covering a searchable original |

## Minimal UI

Word, PPT and Excel appear as ordinary modules and source-picker entries. Modules are slightly smaller to keep ten formats readable in the existing minimum window. The ring remains evenly spaced, and simultaneous automatic releases reserve opposite exit positions. There are no extra task dashboards or engine-selection controls. PDF replacement options remain collapsed with the existing advanced parameters.

Office availability is shown in Settings. Independently installed LibreOffice is detected in `/Applications` or the user's `Applications`. A signed sandboxed build uses the system NSUserUnixTask API and a fixed, verified script in its Application Scripts folder; initial activation uses one native folder grant in Settings. This does not relax the app's sandbox entitlements or install LibreOffice automatically. The helper bounds logs, enforces a timeout, responds to a cancellation file, and controls only its own child process. Unsandboxed development builds use a direct child process on the main run loop so Foundation observes termination reliably. No Python sidecar or browser runtime is bundled.

## Document behavior and limits

- Original files are copied through the existing task workflow. Conversion intermediates and isolated LibreOffice profiles are temporary. Macro execution is disabled in each conversion profile.
- Markdown extraction reads only the OpenDocument body; template master styles, headers and placeholder page fields are excluded. Excessive nonempty tables fail explicitly rather than silently dropping columns or rows.
- HTML scripts and external loads are blocked. Embedded data images are printed; remote and sibling Markdown images retain alt-text placeholders. ZIP/EPUB extraction is not included.
- PDF replacement is exact and case-sensitive, within one text line. Changed regions use a white background. Modified pages are rasterized at up to 3× / 3508 pixels and receive searchable unchanged text plus replacement text. Other pages remain original. Page boxes/rotation are preserved; interactive annotations and vector editability on changed pages are flattened. Missing matches, multiline matches and replacements that cannot fit at 8 pt fail clearly.
- Optional replacement fields decode from old task metadata without migration. Completed Office Markdown tasks recover through the existing result receipt and inspection APIs.

## Verification evidence

Synthetic fixtures cover doc/docx, ppt/pptx and xls/xlsx, with tables, multiple slides and multiple sheets. Retained outputs are in `output/native-capabilities/`. Raster review confirmed readable Office outputs, HTML pagination, a genuinely embedded red image, and removal/replacement of PDF text. The source-byte preservation checks remain in the tests.

The native review app at 760-point width imported a Word fixture, processed it, displayed the result in the existing PDF reader, and saved `app-word-export.pdf`. Excel → Markdown was also processed, previewed and saved as `app-excel-export.md` in dark appearance, with only the two worksheets and their table data. The ten-format orbit was captured in the same window. Screenshots are emitted inline in the task; no mock browser UI is used.

A separate ad-hoc signed probe retained the production sandbox entitlements and used only its own test component in `~/Library/Application Scripts/com.transall.capability-probe`. It completed all six modern Office routes, HTML → PDF and cancellation of an active conversion component. Its retained outputs use the `sandbox-` prefix. The probe's test component is not installed into the production application's scripts directory.

Logs: `/tmp/transall-capabilities-{swift,regression,xcode-final,release,analyze,format,project,review,probe}.log`. Earlier interrupted or failing logs record issues fixed during development; only final successful runs are release evidence.

Final validation: 241 strict SwiftPM tests passed; the final Xcode run passed all 241 tests after the body-only extraction correction. The focused capability regression suite also passed all 9 tests. Release build, Release static analysis, strict formatting, XcodeGen consistency and whitespace checks passed. The one-time production component activation panel was implemented but was not exercised end-to-end; the isolated sandbox probe used a preinstalled test-only copy.

Final handoff: closed the isolated review and probe apps, removed the probe executable, probe-only component script and six generated UUID temporary directories, and retained the exported samples. Reloaded the canonical Release app, confirmed the Word/PPT/Excel modules, and manually restored the user’s prior empty PDF → translated PDF selection, DeepSeek / pure translated PDF / en → zh defaults, empty glossary and expanded advanced parameters.
