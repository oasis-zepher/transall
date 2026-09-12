# Native duplicate-module regression — 2026-09-13

The user screenshots showed a duplicate PDF drawn at a hidden ring host: over the translation module while leaving the chamber, and behind the dragged PDF near the reserved return position. This was introduced by the previous handoff fix, which instantiated hidden labels/glass and relied on ancestor opacity zero. That is insufficient inside the native glass group.

Reverted only the pre-render visibility expression to `concealed: !visible`. Hidden hosts again contain only clear gesture geometry; labels and glass are not constructed. Existing handoff alignment, color interpolation and ring positioning are retained.

Actual native rendering verification used an isolated review build of the same FormatRouterView with its private drag state fixed at the two screenshot stages. The old visibility expression reproduced the overlapping label at the top and duplicate glass near the rim. The corrected expression removed both in A/B screenshots at identical coordinates. These are real native component screenshots of fixed states, not actual pointer-drag recordings; continuous motion remains outside this verification. Review scaffolding is ignored under `.build/orbit-overlap-review` and is not included in Release.

Release build, strict formatting and whitespace checks passed. The isolated review app was closed, and the canonical Release app reloaded with the user's empty selection. No processing or storage code changed.
