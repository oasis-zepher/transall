# Independent PDF editor — 2026-09-15

## Delivered

- Separate top-level PDF 编辑 page alongside 格式转换. No hourglass, conversion parameters, result bar or conversion actions appear in the editor.
- A root-owned editor model retains its document/history across page switches; the conversion page retains its local route presentation state.
- Native open/save panels; selection-specific single-line replacement or deletion; undo/redo; page navigation and zoom; Save As protects the original file.
- Range matching targets one occurrence on one page. Existing batch find/replace keeps its original behavior.
- Cmd-O routes to the currently displayed page; conversion's own import guard still enforces task availability.

## Verification

- Final strict SwiftPM run: 290 tests in 11 suites passed, including three editor regressions covering duplicate occurrences, undo/redo, save/reopen, source protection, deletion, invalid/overflowing edits and annotation rejection.
- Initial full run had one test fixture assumption failure (PDFKit adds a popup alongside a text note) and OCR timing failures. The annotation test now compares the original annotation count; the 11 conversion cases passed in focused retest, followed by the complete 290-test pass. No unrelated OCR code changed.
- Release build and static analysis passed with complete concurrency checking and warnings as errors.
- Changed Swift files passed strict formatting. Generated project consistency, release metadata and 36 metadata validator fixtures passed. git diff --check passed.
- Exported two-page fixture reopened with one DOG and three CAT occurrences, retained the untouched paragraph, and preserved original source bytes. Poppler-rendered first page visually reviewed.
- Actual Release app showed the independent navigation and empty editor page, and its native PDF file chooser. App installed at /Users/zephyr/Applications/Transall.app and code signature verified.
- UI automation timed out after selecting a PDF in both the temporary build and installed app. Process sampling showed an idle main thread with PDFKit analysis running on a background queue. This does not establish the cause. Mouse selection, apply/undo interactions, loaded-page switching and the save-panel round trip remain unverified in the real app; backend tests are not a substitute for those checks.

## Limits

- White-background/system-font replacement, not general PDF object editing. Changed pages are rasterized; the text layer remains searchable.
- Single-line selections up to 512 UTF-16 units; oversized replacement text is rejected instead of being reduced below the renderer's minimum size.
- Annotated/form pages are rejected for original-text editing; encrypted or edit-restricted documents are rejected at opening.
- Undo history is bounded (20 snapshots, approximately 100 MB with at least one snapshot retained). Unsaved editor state is retained only while this window/session exists; save before quitting.
- Xcode scheme tests were not separately executed; validation used the strict SwiftPM suite plus Release build/analyze.

## Local evidence

- /tmp/transall-pdf-editor-final-tests.log
- /tmp/transall-pdf-editor-ui-build.log
- /tmp/transall-pdf-editor-review/editor-source.pdf
- /tmp/transall-pdf-editor-review/editor-edited.pdf
- /tmp/transall-pdf-editor-review/editor-edited.png
