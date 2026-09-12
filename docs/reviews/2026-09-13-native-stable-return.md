# Native stable return — 2026-09-13

## Confirmed cause

A controlled native replay of the complete production settlement method reproduced a post-arrival jump. The returned PDF reached (412.5369, 107.0842), but the first ring frame after commit used the old parent-bound ordering and placed it at (155.4631, 107.0842). It then animated back toward the intended gap. The preceding hidden-host fixes did not protect this one-frame stale ordering.

## Change

The committed ring order is retained locally until the parent binding reflects the same order. Clearing the drag presentation no longer exposes an old order. Each format also keeps one persistent visual across ring, active drag and direct return; its native glass and label are not swapped at arrival. Clear pointer/keyboard targets are separate from painted module visuals. Hidden formats still do not paint glass, avoiding the prior duplicate-module regression. Color previews, final role-color interpolation, circular movement, compatibility checks and cancellation remain connected to the existing model.

## Runtime evidence

An isolated review build used the actual FormatRouterView, stable visual and settlement code. Review-only controls initialized a drag state, invoked settlement and cancellation, and logged presented coordinates and label lifecycle during real SwiftUI animation. They did not inject mouse events or modify user documents. The test exercised return, cancellation, and a second return after cancellation.

| Measurement | Before order fix | After order fix |
| --- | --- | --- |
| Maximum post-commit displacement from arrival point | 257.0738 pt | 0 pt on both returns |
| Additional label/surface creation at arrival | Not relied on | None |
| Duplicate painted PDF in observed states | None in persistent-visual replay | None |

Raw before/after pose and geometry traces and computed metrics are retained under `output/native-orbit/stable-return-*`. The review scaffold is ignored under `.build/orbit-overlap-review`; none of its controls, logging or test state is shipped. Real native screenshots were emitted in the task. This validates the full controlled settlement animation, not live mouse dragging; the existing mouse tool limitation remains.

Final checks: 37 strict WorkbenchTests passed; Release build, strict formatting and whitespace checks passed. The isolated review app was closed and the canonical Release app reloaded with its original empty selection. No browser, icon, engine, storage or export changes were made in this fix.
