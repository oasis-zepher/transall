# Native hourglass selector — 2026-09-12

This follow-up implements the approved hourglass and incompatible-proximity plan. It supersedes the separate central slots and non-draggable unavailable modules in the [orbit report](2026-09-12-native-orbit.md). Changes are confined to the native app, its tests, generated project and design documentation; existing browser and icon edits are preserved. Conversion engines, persisted task formats and export interfaces are unchanged by this follow-up.

## Exit clearance and slower waist entry

The outer ring now rotates together at equal angular spacing to reserve the active upper/lower extrusion corridor plus an 8-point margin. It holds the gap until a cancelled bulb finishes retracting or a committed module reaches the ring. Hidden incoming/outgoing modules do not count as obstacles. This addresses the screenshot's overlap with the upper HTML module.

Waist-side proximity now ramps through the chamber instead of reaching full morph at its rectangular hit edge. Incoming morph and attached release preparation share a 780 ms ease-in-out approach; valid mouse-up settles over 640 ms, and retreat restores over 280 ms. The existing 22% gentle attraction is retained. These timings supersede the older entries below; flip timing remains 420 ms.

Validation: 232 strict SwiftPM tests and 232 Xcode tests passed, including new symmetric/monotonic waist approach and upper/lower corridor intersection checks at 300, 431 and 580 points. Formatting, XcodeGen consistency, Release build and static analysis passed. The latest Release was reopened in the system dark appearance and restored to the observed image → PDF selection with no input. Native static production-component screenshots show both attached bulbs clear of the ring at 431 points. The 760-point review window completed text-data-to-image source replacement and returned the old module to the ring. Screenshots were emitted inline in the task; the two-outlet fixture is explicitly labeled static, not a gesture recording.

Actual coordinate drag from below was retried and failed with `Computer Use server error -10005: noWindowsAvailable`. Continuous hover, changing approach speed, and mouse-release handoff remain unverified by real mouse; tests and static screenshots do not replace that check. Logs: `/tmp/transall-clearance-{swift,xcode,build,analyze,format,project,review}.log`.

## Anticipatory replacement and continuous handoff

The attached old module now begins extruding during compatible replacement proximity, rather than waiting for the selection to commit. Distance drives preparation continuously up to progress 0.50 (below the 0.62 separation point). Leaving the slot or invalid release retracts it over 220 ms without mutating the selection, input files or options. Valid mouse-up advances the same attached bubble toward 0.60 while the incoming module settles; selection commit then continues that presentation into separation and travel.

The release layer retains a stable view identity for each format throughout approach, retraction and departure. Commit preserves each matching presentation’s progress instead of removing the preview and creating a new animation at zero. Remaining duration is shortened for a prepared module, with a 480 ms minimum so the ring finishes redistributing before handoff. Click/keyboard replacement without proximity still begins at zero. Invalid replacements, swaps, retained duplicate formats, task locks and Reduce Motion do not prepare an ejection. Resize and route-lock cancellation clear stale preparation.

New regression coverage verifies continuous proximity progress, preparation/settlement staying attached, draft and file preservation, unsupported/same-format/locked rejection, retained duplicates and swaps, plus remaining-duration limits. Logs: `/tmp/transall-anticipation-{swift,xcode,build,analyze,format,project,review}.log`.

230 strict SwiftPM and Xcode tests passed; Release build/static analysis, strict formatting, project consistency and whitespace checks passed. Real App screenshots and accessibility states confirmed a normal click replacement still exits and restores the ring and controls. The fresh pointer attempt failed with `Computer Use server error -10005: noWindowsAvailable`, so continuous hover preparation, retreat and mouse-up handoff remain unverified by physical mouse. The final Release was reopened and restored to the observed PDF → Markdown selection with default language and no input.

## Exocytosis-style release

The user requested that replaced modules squeeze out through the top/bottom rather than leave as a lifted half-hourglass. Released source formats now bulge through the top lip, target formats through the bottom lip. For the first 62% of a 960 ms presentation, the module grows outside the lip while remaining attached by a neck that progressively narrows. Horizontal movement stays zero. After the neck reaches zero, the module detaches and curves to its reserved ring position.

The bulb and neck form one unioned native-glass silhouette, clipped at the outside lip while attached. Opaque mode uses the existing shared control fill. The icon fades in during growth; the format name fades in after the small bud stage to avoid clipped text. The role gradient and rounded module shape return during departure. Existing clear/removal deduplication, selected-neighbor ordering, task locks and Reduce Motion bypass remain in place; gentle drag attraction is unchanged.

A production-component static fixture was captured for both roles at 22%, 49% and 72%. It confirms the attached bulge, narrowing neck and detached module, and exposed early clipped text which was corrected. This fixture is explicitly labeled as static; it does not establish continuous gesture or animation quality. Regression coverage checks attachment outside the lip, exclusion of the chamber interior, disappearance of the neck before lateral travel, exact destination and normal final size at three orbit sizes. Logs: `/tmp/transall-extrusion-{swift,xcode,build,analyze,format,project,review}.log`.

Final production-source validation: 228 strict SwiftPM and Xcode tests passed; Release build/static analysis, formatting and project consistency passed. Live accessibility-triggered replacement screenshots captured a target module still connected below the lip and a source module after separation traveling toward its ring position, followed by restored controls and ring modules. These are real animation samples, not a continuous mouse recording. The canonical app was observed on image → OCR with default language/output and no input; it is restored to that selection after loading the new Release.

## Gentle-attraction rollback and top-edge correction

The user clarified that the reported mismatch concerned the top of the morphed half versus the highlighted cavity, and rejected the new forced alignment feel. Full pointer attraction has been reverted to the original **22% gentle attraction**. The color treatment, replacement morphing and returning-module animation are retained.

The visual defect was the distinction between the 68-point drop hit region and the 84-point visible half: target highlighting started 16 points below the waist, while the morphed module included that section. Highlight rendering now uses the same full half-hourglass contour and presentation frame as the module, outside the hit-region view. Drop validation still excludes the waist. Regression tests now protect the gentle attraction and equal top edges rather than requiring snap-to-center during hover.

Validation logs: `/tmp/transall-topedge-{swift,build,analyze,format,project}.log`. 227 strict SwiftPM tests, Release build/analysis, strict formatting and generated-project consistency passed. The Release App was reopened with the observed source-only image selection restored. A fresh pointer attempt again returned `noWindowsAvailable`; physical drag feel and the hover highlight were not visually verified in motion.

## Alignment, vacancy material and replacement follow-up

The user's 22:14 screenshot exposed a fully morphed target module still offset from the empty slot. The old attraction stopped at 22% of the required displacement while the shape reached 100%. The same review also identified absent replacement morphing and abrupt old-module ejection. This section supersedes the earlier proximity, color and release implementation details.

- `OrbitDragVisual` uses a single animatable presentation for signed contour deformation, attraction, contraction and release progress. Full deformation means full alignment to the corresponding 84-point half, regardless of pointer pickup offset. Nested independent geometry animations are suppressed so shape and position do not lag separately.
- Unsupported portions of the role gradient expose the **same unfilled native glass** as the hourglass. Supported halves retain native white/near-black. Both hourglass and modules share the system control fill in opaque mode. No sampled screenshot color, painted highlights or simulated glass is used.
- Occupied chambers now participate in proximity feedback. The chamber under the pointer wins over the neighboring role, and the existing replacement/swap validator decides compatibility. Hovering never mutates the draft; invalid drops preserve it.
- An outgoing format begins at the exact half-chamber center in the half-hourglass contour and chamber material. Over a 680 ms curved departure, a shared progress value restores the rounded module and crossfades its chamber label into its ring label. Source exits upward; target exits downward. Deduplication, gap insertion, locks and reduced-motion behavior remain unchanged.

Latest automated validation: **227 SwiftPM tests passed**, including arbitrary pickup offsets at three orbit sizes, exact upper/lower half placement, valid/invalid occupied-slot feedback, draft preservation, outgoing contour endpoints and all existing processing/export tests. Xcode also passed 227 tests; the final animation-duration/fallback adjustments passed strict SwiftPM and Release compilation. Release static analysis, recursive strict formatting, XcodeGen consistency and whitespace validation passed.

Actual App screenshots confirm dark vacancy-matched role gradients and successful Markdown-to-OCR replacement with the old Markdown module restored to the ring. A separate **explicitly labeled static production-component fixture** shows exact alignment for source and target halves with a deliberately offset pickup anchor. It does not represent a physical drag recording. The current real pointer attempt again failed with `Computer Use server error -10005: noWindowsAvailable`; continuous drag, replacement morph timing and ejection smoothness remain unverified. No unit test or static screenshot is presented as a substitute.

Logs: `/tmp/transall-docking-{swift,xcode,build,analyze,format,project,review}.log`. The canonical app was observed on 文本数据 → PDF with no input; the updated Release was opened and restored to that selection.

## Opposite-side buttons, half-hourglass morph and role gradients

This latest refinement supersedes the button placement and generic unavailable caption described in the historical sections below.

- Flip sits to the **left** of the waist and Clear to the **right**, at the same height. Layout tests check symmetry and separation at 300/431/580-point orbit sizes.
- Each module's upper half shows source compatibility; its lower half shows output compatibility. Supported halves use the system page color (white or near-black), unsupported halves system gray. Dark mode mixes gray against the page color so white labels remain readable. Roles update independently of the active slot and operation locks. Generic “不可用” captions and whole-node dimming are removed; role-specific help/AX values and Differentiate Without Color marks retain non-color explanations.
- Compatible proximity continuously morphs a rounded module into the corresponding **84-point half of the actual hourglass**. The existing 68-point input hit areas and waist exclusion remain unchanged. Same-topology curves and a signed morph value avoid instantly mirroring the shape when crossing between upper and lower chambers. Labels and icons keep their size. Incompatible width contraction and Reduce Motion behavior remain intact.
- Release captures the currently displayed magnetic position, rather than dropping the attraction offset at mouse-up. Drag previews now render outside the stationary glass effect container. The hidden ring host can reach its final angle during the 480 ms return, then becomes visible in one transaction after redistribution. Escape during settlement cancels the commit, finishes the current interpolation, and returns home without guessing a presentation position. These address identified discontinuities; continuous pointer smoothness is not yet verified.

### Latest validation

| Check | Result |
| --- | --- |
| Strict SwiftPM tests | 225 tests in 6 suites passed on final source |
| Xcode scheme tests | 225 tests passed; subsequent view-only contrast adjustment also passed strict SwiftPM and Release compilation |
| Release build and static analysis | Passed |
| Strict recursive formatting, generated-project consistency, whitespace | Passed |
| Light minimum window, empty and PDF → Markdown | Actual App screenshots: opposite-side controls, mixed/full gray modules, readable labels, no overlap |
| Dark minimum window | Actual App screenshot exposed overly bright gray; corrected and recaptured with darker gray and readable white labels |
| Unsupported HTML output click and named accessibility assignment | Both left source-only PDF selection unchanged |
| PDF ↔ Markdown and Clear via accessibility buttons | Correct endpoints, role-color updates, temporary locks and complete ring return observed |
| Half-hourglass shapes | Production component rendered at 0/50/100% for both roles in an isolated App fixture; labels fit. Static fixture is explicitly labeled, not presented as a mouse recording |
| Real mouse dragging | **Unverified:** current attempt again failed with `Computer Use server error -10005: noWindowsAvailable` |

Regression coverage adds independent role availability and locked-action rejection, sampled containment equivalence with both actual hourglass halves, neutral shape between signed morph directions, magnetic position continuity, incompatible/no-motion attraction exclusion, and horizontal control separation. Existing local conversion/export/original-preservation tests passed. The earlier live accessibility/system-accent checks remain historical evidence; the new gradient was not re-exercised with every live accessibility setting. macOS 14–15 runtime remains unavailable.

Screenshots were emitted inline from actual App windows. The ignored `.build/workspace-review` harness renders production components with isolated data/preferences; no fixture is shipped. Logs are `/tmp/transall-morph-{swift,xcode,build,analyze,format,project,review}.log`. The canonical App was observed with an empty selection before restart; the final Release is left in that state.

## Dual buttons and released-module follow-up

The next user refinement adds separate **倒转** and **清空** buttons beside the waist and removes the bottom **重新选择** button. Clearing uses the existing draft reset and preserves stored generated jobs.

- The ring now retains its circular order within the current window, including across document/orbit navigation. A selected module dragged back near the rim reserves a gap. On release, it is inserted between the chosen neighbors, including the wraparound pair; invalid/cancelled drops retain the previous order.
- Replacement, chamber removal and clearing return only formats no longer present in either chamber. The old source leaves upward, the old target downward, along a 560 ms curved path before joining the ring. PDF → PDF clearing returns only one PDF module. A flip releases neither format.
- The stationary glass group excludes the traveling modules. Real screenshots initially showed blurred traveling labels when the two shared one effect container; the separate rendering layer fixed the captured return state.
- Both buttons respect route locks, dragging, flip and return animation. Reduce Motion commits the same ordering without travel. Clear's disabled state does not depend on a wall-clock cooldown, so it cannot remain disabled after an otherwise completed drag.
- Added tests cover every gap for rings of three to six nodes, chosen-neighbor preservation, cancellation-safe value plans, replacement/clear/swap deduplication, outgoing chamber direction, trajectory endpoints, and two-button separation at 300/431/580-point orbit sizes.

Real light/minimum-window checks captured both buttons, replaced target Markdown with OCR, replaced source PDF with image, cleared distinct and same-format selections, and confirmed the complete seven-module ring afterward. The screenshot taken while the corrected clear animation was pending showed readable traveling PDF and Markdown labels. These are sampled states, not a measurement of continuous smoothness.

The new direct source-to-ring mouse drag attempt again returned `Computer Use server error -10005: noWindowsAvailable`. Actual pointer-based gap insertion and continuous drag animation remain unverified. Final checks passed: 222 tests each in SwiftPM and Xcode, Release build/analysis, strict formatting, generated-project consistency and whitespace validation. Logs use `/tmp/transall-return-{swift,xcode,build,analyze,format,project}.log`. The final Xcode result is `Test-Transall-2026.09.12_21-41-03-+0800.xcresult`. The final Release app also showed both buttons in dark appearance and was restored to the observed Markdown → PDF path with no input. No system settings were changed in this follow-up.

## Original hourglass implementation

- One native Liquid Glass hourglass, 168 points high, 34% of orbit diameter wide and capped at 200 points. Source and target chambers have independent buttons, drop validation, accessibility labels and removal actions. The waist rejects drops, including occupied-module releases that would otherwise remove the module.
- The shell and foreground content share one glass effect. Initial real screenshots exposed blurred chamber labels when a separate glass sibling treated them as background; applying the effect to the complete chamber content fixed this. No stacked chamber glass, painted highlights, falling sand or countdown effects.
- Within the existing 64-point continuous proximity range, a compatible empty chamber elongates the module toward its bounds over 420 ms and attracts it slightly. An incompatible empty chamber contracts width toward 85%, leaves label/icon dimensions intact, and applies no attraction. Leaving restores the shape over 220 ms. Hovering an occupied chamber does not activate a neighboring empty chamber's morph.
- Gray modules remain draggable with “不可用” visible. The approach hint distinguishes “不能用作源格式” from “不能用作目标格式”. Click, keyboard activation, context menus and named accessibility actions use compatibility checks; invalid release/selection preserves the draft.
- Existing equal-angle orbit redistribution and invalid-release return behavior are retained. Reduce Motion removes rotation, redistribution travel, morphing and attraction while retaining compatibility messages.
- A native SF Symbol button beside the waist queries one reverse-selection validator. Empty/same-format selections and unsupported reverse routes have specific disabled reasons; valid partial selections may move to the other role. Import, submission, processing, save and deletion locks are honored. The view additionally locks during dragging and flipping.
- A supported reversal animates the shell and format positions through 180 degrees over 420 ms, with upright format labels and fixed role captions. A captured selection and presentation ID reject stale completions and repeated submission. Valid reversal publishes the selection exactly once, clears files/preview, restores defaults and retains stored generated data. It never promotes a result into a new input. Escape, view removal, resize and operation/selection changes cancel pending presentation.

## Automated validation

| Check | Result |
| --- | --- |
| Strict SwiftPM tests | 218 tests in 6 suites passed |
| Xcode scheme tests | 218 tests in 6 suites passed |
| Release build | Passed |
| Release static analysis | Passed |
| Strict recursive Swift formatting | Passed |
| XcodeGen 2.46.0 project consistency | Passed |
| Whitespace validation | Passed |

New coverage checks single-publication reversal, default/draft/preview reset, stale/replayed requests, unsupported paths, empty/same/partial selections, import/submission/deletion locks, compatible and incompatible proximity, 85% width, Reduce Motion geometry, occupied-region exclusion, and waist rejection at 300/431/580-point orbit sizes. Existing saving and running-lock tests now explicitly reject a reversible selection. The generated-job test confirms stored completed output survives reversal and still enforces result integrity. Existing nine-route synthetic processing/export and original-preservation checks also passed.

## Real App checks and screenshots

Actual App screenshots were captured with CUA and emitted inline in the implementation conversation. The small-window review app uses production views and independent data/preferences; its entry point is ignored under `.build/workspace-review`, not shipped.

| State/action | Observed result |
| --- | --- |
| Light 760 × 680 content window, empty hourglass | One shell, readable role captions, seven ring modules and separate waist button |
| Light minimum window with inspector, Markdown → PDF and PDF → Markdown | No chamber/ring/button overlap; labels fit and remain upright in settled states |
| Single PDF reversal | Source-only PDF moves to target-only PDF, then allows compatible source selection |
| PDF ↔ Markdown | Both endpoints update correctly; AX reports the flip button and local selector actions disabled while the animation is pending |
| Image → PDF | Flip is disabled with “暂不支持 PDF → 图片”; image-only reversal also explains that images cannot be targets |
| PDF → PDF | Flip is disabled with “源格式与目标格式相同” |
| Gray HTML click / named target-assignment action | Selection remains unchanged; gray nodes remain AX-enabled for dragging |
| Live system accent change to purple | Chamber contents and active role follow the system accent; restored to original Multicolor |
| Live Increase Contrast | Single opaque shell with clear outline; unavailable status remains textual |
| Live Reduce Transparency | Opaque shell and modules; no added glass layers |
| Live Reduce Motion | Reversal directly reaches the new selection without an intermediate pending AX state; settled screenshot is correct |
| Final Release, dark appearance | Empty and selected hourglass screenshots show one native glass surface with clear foreground content |
| Final Release, imported draft | Imported the 12-page synthetic PDF, confirmed native PDF text/page count, changed recognition language to en-US, and returned to the orbit with the draft intact |
| Invalid selection with that draft | Gray click and accessibility assignment preserve the route, document entry and edited recognition language |
| Valid reversal with that draft | Changes to Markdown → PDF, removes “查看文档”, disables Start until new input, and clears the prior draft; reversing back restores zh-Hans,en-US defaults |

Increase Contrast, Reduce Transparency and Reduce Motion were initially off and were restored to off. Appearance was left at the original Automatic setting. The final Release app was restored to the original PDF → translated PDF route, no input, en → zh, DeepSeek unconfigured.

### Runtime verification limitation

**Real pointer dragging remains unverified.** Attempts in both the review app and the newly built Release app returned `Computer Use server error -10005: noWindowsAvailable`. Therefore compatible elongation, incompatible contraction, proximity/departure transitions, invalid pointer release, continuous orbit motion and continuous flip-animation smoothness are **not claimed as verified**. Accessibility-driven flip endpoints, pending-operation locks and real static screenshots do not replace that mouse/animation pass. Rapid physical repeated clicks and a full keyboard/VoiceOver traversal were not independently exercised. macOS 14–15 were unavailable; their fallback branches compile against the macOS 14 deployment target.

## Artifacts

- App: `native/TransallMac/.build/workspace-validation/Build/Products/Release/Transall.app`
- Tests: `/tmp/transall-hourglass-swift.log`, `/tmp/transall-hourglass-xcode.log`
- Release: `/tmp/transall-hourglass-build.log`, `/tmp/transall-hourglass-analyze.log`
- Format/project: `/tmp/transall-hourglass-format.log`, `/tmp/transall-hourglass-project.log`
- Xcode result bundle: `native/TransallMac/.build/workspace-validation/Logs/Test/Test-Transall-2026.09.12_21-14-09-+0800.xcresult`

The [workspace report](2026-09-12-native-workspace.md) retains the earlier rendered-export and document-reader evidence.
