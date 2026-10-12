# Native PDF translation layout repair — 2026-09-13

## Problem and reference

The reported 10-page paper became a 31-page bilingual text PDF because native `bilingual` used `writeTextPDF`. The web and native implementations are separate: the web can use BabelDOC, while the native app previously reflowed bilingual output. This is an implementation gap, not a limitation of the user's paper.

Inspected Larryppg/auto_pdf_translator at commit `5f384c0ec0035f5a1c41ba811acfd5087dc56223`, specifically its PDF extraction/OCR and document-context/batch-translation workflow. The native repair adopts paragraph regions, image OCR deduplication, document-level terminology context, stable IDs and validated region mapping, and fitting translated text back into the original geometry. It does not claim to use the same engine or to have equivalent quality on every document.

## Changes

- Default translated PDF output preserves layout; bilingual uses the same layout route and places matching original/translated pages side by side on each output sheet (original left, translation right). The initially implemented alternating-page layout was explicitly rejected by the user and has been replaced. Plain text is an explicit separate mode.
- Bilingual preview directly displays the same verified wide-page PDF used for download. There is no second original pane around the already paired PDF and no alternating-page extraction. Each original page produces one comparison page.
- Ignore PDFKit U+FFFC image placeholders as text. These previously created masks the size of entire figures and suppressed genuine OCR labels.
- Use dominant text font rather than an affiliation superscript; rejoin adjacent author runs before grouping paragraphs; preserve font weight, alignment, and color.
- Keep small labels at their original preferred size instead of imposing an 8 pt enlargement. Unchanged symbols/names remain visually untouched with a searchable text layer.
- Analyze document terminology once and include that context in translation batches and missing-region retries. Preserve names, DOI, genes, numbers, formulas, and units.
- Remap internal links when writing translated and bilingual PDFs, including rotation, panel placement, and cross-page destination coordinates. The paper itself has missing named targets `cor1` and `appsec1`; retain their annotation appearance without writing invalid destinations.
- Overflow still fails with retained translation recovery data; there is no automatic fallback to a reflowed plain-text result.

## Verification completed

- 22 targeted tests in four suites passed with strict concurrency and warnings treated as errors. Coverage includes geometry/rotation/annotations, embedded figure placeholders and OCR, small labels, searchable symbols, left/right text isolation and link mapping at all four rotations, recovery, progress, context injection, and missing-region retries.
- Release Xcode build succeeded. Final Release installed at `.build/workspace-validation/Build/Products/Release/Transall.app` and launched through the actual App UI. Previous builds retained as local backups.
- Swift formatting checks and `git diff --check` passed.
- Extracted the user's 10-page paper: 489 regions (109 native paragraphs/blocks and 380 OCR regions).
- Offline layout fixture: seven changed regions, including a Chinese title and complete Chinese abstract, with all remaining source regions preserved. Rendered all ten pages and inspected the contact sheet plus full-page first and seventh pages. Double columns, figures, and tables remain visible; the Chinese abstract fits its original area.
- Offline monolingual fixture has 10 pages and 190 valid internal links. Bilingual fixture initially had 20 alternating pages. After the user clarified the requirement, the corrected fixture has 10 wide pages with original on the left and translation on the right. Latest rendering and link checks are recorded in `/tmp/transall-side-by-side-render.log` and `/tmp/transall-side-by-side-tests.log`.

## Not yet verified

No new DeepSeek request has been made for the complete paper. macOS Keychain access blocked the live rerun; the user was asked to handle its system permission prompt. Computer Use refused access to SecurityAgent. The offline fixture is **not** a completed translation and is not delivered as one. Full-paper wording, every translated figure label, and end-to-end translation/download in the updated app still require the live rerun and rendered inspection.

The original job and its 31-page result were preserved. Real-paper files and the offline fixture live only in the untracked local `output/pdf/translation-quality-2026-09-13` workspace; do not commit them as test fixtures. No full-suite/CI or App Store readiness claim is made.
