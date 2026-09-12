# Native large format orbit — 2026-09-12

The [hourglass follow-up](2026-09-12-native-hourglass.md) supersedes the central slots and unavailable-module drag behavior below. This report preserves the earlier orbit implementation evidence.

This follow-up implements the user’s revised preference: use the browser-style large format orbit as the native app’s main entry. It supersedes the task-sidebar entry described in the earlier workspace report.

## Behavior

- A centered orbit, up to 580 points across, presents the seven native formats as rounded modules. Drag into either central slot, in either order; PDF can fill both slots for editing/merging.
- Modules follow pointer translation without jumping to its center. Valid target slots highlight. Releases settle into valid slots; unsupported combinations and catalog drops outside the slots return home without changing the draft.
- Occupied slots can be dragged to swap, move to an empty slot or remove outside the slots. Swaps are accepted only if the resulting combination is supported. Same-slot drops and identical assignments preserve files and parameters. Escape, view removal, resizing and operation locks cancel pending drops.
- Click selection, context menus and named accessibility actions remain available. A short mouse-up suppression interval prevents a completed drag from becoming an accidental click, including when Reduce Motion disables the settling animation.
- Pickup and target feedback, 280–420 ms ease-out settling, inspector changes, and 220 ms document/orbit transitions honor Reduce Motion. Spatial motion is disabled in that mode. System Liquid Glass is applied directly to the module shape with native interactive feedback; Reduce Transparency / Increase Contrast use solid surfaces.
- Route parameters open after each valid new pair, including after removing a slot. Importing opens the document workspace; the toolbar returns to the orbit with the draft intact.
- Existing processing engines, input/result previews, comparison, cancellation, stored jobs, original-file protection and export verification remain unchanged by this follow-up.

## Equal spacing, slot elongation and unavailable states

- Lifted and assigned modules leave the visible ring. Remaining modules are spaced equally and animate their angle over 480 ms, so they follow the circumference. Cancellation, removal and replacement restore the appropriate modules in catalog order.
- The invisible gesture host survives until mouse-up. Its glass content is removed explicitly: retaining only a glass view with zero opacity produced a native rendering overlap, observed in the real App screenshot and fixed.
- Within 64 points of an empty compatible slot, proximity continuously drives the module's elongation, height adjustment and slight attraction toward the slot. Morphing takes 420 ms; departure restores the shape in 220 ms. Text and symbols retain their proportions. Filled or incompatible slots do not trigger elongation. Reduce Motion disables movement and shape morphing.
- Unsupported formats are gray, labeled “不可用”, and disabled. Their status follows the active central slot, including when changing an existing source. Operation locks also disable selection. The PDF module is consumed by selection; clicking the opposite empty slot's “整理 PDF” action keeps PDF → PDF available in either selection order.
- Added tests verify ring membership/order and equal angular spacing, available formats for each selection direction and lock state, and bounded, monotonic proximity strength.
- Final Release also verified the empty-slot PDF-to-PDF shortcut and the dark five-module layout, then restored the previously selected PDF translation route. Actual light/minimum-window screenshots verified six-way and five-way arrangements, gray unavailable modules, source replacement returning the previous format to the ring, and removal of the glass overlap. Pointer drag remains blocked by the CUA window error described below; these observations do not establish drag smoothness or the runtime elongation gesture.

## Verification

| Check | Result |
|---|---|
| Strict Swift package tests | 213 tests in 6 suites passed |
| Xcode scheme tests | 213 tests in 6 suites passed |
| Release build | Passed |
| Release static analysis | Passed |
| Strict formatting, XcodeGen consistency, whitespace | Passed |
| Real Release App | Selected PDF → PDF using the orbit, opened the system file panel, imported a synthetic PDF, entered the document viewer, and returned to the orbit with the draft intact |
| Light appearance / minimum size | Same production views checked in the isolated review app at 760 × 680 content size; circle, nodes, central slots and inspector fit without overlap |

The new routing tests cover both assignment orders for every enabled native route, compatible swaps, moves, removal, invalid/stale drops, no-op draft preservation, accepted-change draft clearing, import/submission/deletion locks. Existing nine-route synthetic processing/export checks continue to pass.

### Drag follow-up runtime evidence and remaining limitation

- Final Release App: selected PDF → PDF, removed and refilled its target, verified that the inspector reopened, imported the 12-page synthetic sample through the system file panel, inspected its PDF text/page count, and returned to the orbit with the file draft retained.
- Real production views were inspected in light appearance at 760 × 680, with and without the inspector. Module labels, slots and inspector fit without overlap.
- Accessibility actions selected OCR first, rejected HTML → OCR without losing that target, then completed PDF → OCR. Slot removal also worked with the system Reduce Motion setting enabled.
- Real screenshots captured Increase Contrast and Reduce Transparency separately: modules switched to opaque surfaces with explicit boundaries. These settings and Reduce Motion were restored to their initial off values and verified. Screenshots are emitted inline in the implementation conversation.
- **Pointer-drag verification remains blocked:** CUA's coordinate drag and coordinate click calls consistently return `Computer Use server error -10005: noWindowsAvailable`, in both the Release app and the independent review app. Accessibility clicks and screenshots work. System Settings also produced one ScreenCaptureKit capture failure. No mouse-drag success or animation smoothness is claimed from these checks; the gesture path needs a manual runtime pass when coordinate control is available.
- macOS 14–15 and a full VoiceOver session were not available for this follow-up. Source branches retain their native control fallback.

The isolated review entry point is ignored under `.build/workspace-review`; it is not shipping code. Source/output validation from the [workspace report](2026-09-12-native-workspace.md) remains applicable.

Logs: `/tmp/transall-orbit-motion-swift.log`, `/tmp/transall-orbit-motion-xcode.log`, `/tmp/transall-orbit-motion-build.log`, `/tmp/transall-orbit-motion-analyze.log`, `/tmp/transall-orbit-motion-format.log`, `/tmp/transall-orbit-motion-project.log`.

App: `native/TransallMac/.build/workspace-validation/Build/Products/Release/Transall.app`.
