# Direct PDF editing — 2026-09-21

## Scope and design

The user requested Foxit-style direct text editing instead of the existing sidebar find/replace interaction. Keep PDF editing separate from the hourglass conversion page. The conversion engine's legacy batch replacement remains independent.

- PDFKit remains the viewer. PDFium 8046 handles PDF content objects, preserving vector paths, images, annotations and other pages.
- A native NSTextView appears on the selected text object. The display copy temporarily omits that object, and a separate unmodified byte snapshot remains the source of the editing transaction. Typing, Chinese input, line breaks, font/size/color changes, text box width and dragging operate on this draft.
- Finish or Save As commits all draft properties as real text objects; cancel restores the source bytes. Undo/redo retains bounded document snapshots. No file is overwritten in place.
- New text uses embedded local fonts, CoreText line layout and a Unicode cmap limited to the entered characters. This avoids CJK radical aliases breaking search/copy. Related runs are marked and regrouped when reopened.
- PDFium is serialized on the main actor. Each document retains its input bytes for its entire native handle lifetime. Xcode and SwiftPM statically link the same pinned universal library. Runtime downloads and Python processes are not used.

## Limits

Simple horizontal page text objects only. Existing source runs can remain separate objects. Scanned images, invisible OCR text, rotated/skewed text, nested form text, special patterns and unsupported page graphics are not editable. The document is not a word processor: nearby content does not reflow when a text box grows. Complex shaping and mixed original formatting are not a complete desktop-publishing implementation. Solid ICC/CMYK colors on the changed page are resolved to RGB because PDFium's content writer does not preserve those color operators. Drafts are kept only in the current window, not recovered after quit.

## Validation

- Regression fixtures cover a two-page vector PDF, colored ICC background, an image and an annotation; direct English/Chinese editing, movement, deletion, object counts, copy/search text, and unchanged second page.
- Model tests cover preview isolation, cancellation, pending-text save, snapshot undo/redo, original-file protection, and invalid edit preservation.
- A CJK regression exposed radical-codepoint substitution in generated ToUnicode and is fixed by using an explicit input cmap. A colored-background render check exposed unsupported color-space serialization and is fixed by resolving supported solid colors before writing.
- Complete strict SwiftPM run: **296 tests / 13 suites passed** (`/tmp/transall-direct-final-tests.log`). An earlier concurrent build/test run hit the existing OCR route timeout; those 11 route cases passed in isolation, and the subsequent complete run passed.
- After the mouse-routing correction, **9 tests / 3 relevant suites passed**, including window-coordinate hit testing, `mouseDown`, native NSTextView input, Chinese/newline text, zoom preservation, and input-field hit targeting (`/tmp/transall-direct-final-editor-tests.log`). The same native mouse regression failed against the previous responder behavior before the fix.
- Release universal build and analysis passed (`/tmp/transall-direct-final-build.log`). XcodeGen consistency, strict Swift formatting, release metadata, all 36 metadata regression fixtures, and `git diff --check` passed.
- Installed `/Users/zephyr/Applications/Transall.app`; deep/strict code-signature verification passed. Executable SHA-256 matches the built product: `418dbbabd1f687b7d0378963a90d38dca4f331000f8b80e3b0fb79276d95c343`. The editor is statically linked; sandbox/hardened-runtime configuration is retained, without a PDFium dylib or library-validation exception.
- Poppler-rendered exported pages were inspected. Background color, line art, Chinese and English text were visible. PDFKit and Poppler both read back the exact Chinese characters rather than radical aliases. Test artifacts: `/tmp/transall-direct-review/direct-before.pdf`, `direct-after.pdf`, and `native-inline-view.png` (offscreen native input-view render, not an installed-App screenshot).

## Actual App observations and verification limit

- The installed App launched. The editor's attached open sheet left valid PDFs selected with its Open button disabled in the current macOS 27.2 environment. Using the existing conversion page's standalone `begin` presentation made Open selectable and functional. Save uses the same presentation style.
- The user confirmed that the PDF displayed normally, but clicking text did not initially enter editing. PDFKit's internal document view consumed mouse events. The final implementation explicitly routes page hits to the editing responder while preserving native text-input and scrollbar hit targets; it no longer relies on a local event monitor.
- CUA repeatedly times out reading the window after a PDF is loaded, although the App responds to Open commands and process sampling shows an idle event loop. Thus the installed-App drag/save sequence has not been fully observed by automation. After installing the responder correction, the user explicitly confirmed that clicking “Edit this text” opens the text box with a caret and permits direct typing. The native view regression additionally covers input, zoom and commit, while exported-document tests cover Save As and text readback.
- Finder cross-application physical dragging remains unverified. Existing provider/pasteboard and route tests pass; this change retains that import infrastructure.
