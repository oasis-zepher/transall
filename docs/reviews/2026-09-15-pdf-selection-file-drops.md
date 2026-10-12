# PDF selection and Finder file drops — 2026-09-15

## Causes and fixes

- The user's four-cell selection has a PDFKit range containing a trailing newline, while its visible selection string contains only the letters. Trim boundary whitespace before single-line validation and retain the adjusted source range.
- The same PDFKit boundary behavior can select a preceding glyph when restoring text after the replacement range. Trim whitespace from retained-run boundaries too. A reopened result is now checked by selecting the original rectangle, so an invisible leftover glyph fails the regression.
- Comb-style text is replaced per glyph, retaining intervening rules and original cell positions. Replacement attempts to retain the source font and color; too many letters fail instead of overwriting adjacent cells.
- Previously only WorkspacePreviewView had a URL drop destination. The hourglass page and independent editor had none. A root file-url receiver now routes to the active page. Native PDFView subclasses explicitly forward file drags rather than swallowing them.
- Finder file-url item providers are decoded in order; native pasteboard URLs use NSURL reading. The editor accepts one PDF and protects unsaved edits. Conversion appends files, respects task locks/current formats, and infers a supported route if no complete route is selected.

## Validation

- 296 strict SwiftPM tests passed, including actual-file selection/edit/save/readback and new file-drop provider/route/batch validation.
- A subsequent text-layer boundary correction passed 15 affected editor/capability tests, including the actual-file rectangle assertion.
- Final Release build and static analysis passed; changed-file strict formatting and git diff --check passed.
- Original bytes of the user-provided source PDF remained unchanged. A temporary test copy was edited and reopened; Poppler rendering confirmed the character-cell rules remain intact.
- Actual installed app: opened the Downloads PDF using the native picker, mouse-selected its four-cell text, typed a test replacement, applied it, saved a temporary copy through the save panel, and used Undo. The inspector now enables editing for that selection.
- Actual mouse testing exposed a hidden trailing old glyph in the first saved copy; the subsequent boundary correction removes it in reopened-PDF tests. The final binary includes this correction.
- Two attempts to drag from Finder across windows through the computer-use tool changed Finder selection but did not deliver a drop to Transall. Cross-application Finder drag behavior is therefore not claimed as manually verified. User feedback was requested while the updated drop handling was running.

## Scope and remaining limits

- White-background text editing; changed pages are rasterized and supplied with searchable text. This is not a general PDF object editor.
- Annotated/form-widget pages remain protected from original-text editing.
- No original files were overwritten or sent to a service.
- Previous user changes outside these fixes were retained. No Xcode scheme test run was performed separately from SwiftPM.

## Local evidence

- /tmp/transall-pdf-editor-fix-final-tests.log
- /tmp/transall-pdf-editor-layer-tests.log
- /tmp/transall-pdf-editor-fix-final-build.log
- /tmp/transall-registration-edited.pdf (final backend output)
- /tmp/transall-registration-ui-test.pdf (earlier UI output before the text-layer correction)
