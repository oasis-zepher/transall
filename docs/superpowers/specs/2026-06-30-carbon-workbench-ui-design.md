# Carbon Workbench UI Redesign

## Context

transall is a local macOS document workbench for file conversion, PDF edits, OCR, PDF translation, and preview. Users need fast repeated operation, clear diagnostics, and visible outputs. The UI should feel like a private local tool, not a marketing page.

## Chosen Direction

Use the local `awesome-design` preset `design-presets/ibm/DESIGN.md` as the main visual reference.

- Light-first productive interface.
- IBM Carbon-like 8px grid, flat surfaces, clear dividers, and blue interaction state.
- Sharp rectangular controls with minimal radius.
- Dense but readable panes for upload, parameters, logs, artifacts, and PDF preview.

## Scope

Modify only the static frontend and frontend tests:

- `app/static/index.html`
- `app/static/styles.css`
- `app/static/app.js` only if required for state hooks or asset versioning
- `tests/test_frontend_transition.py`

Do not change backend conversion, translation, OCR, file storage, or API behavior.

## Layout

Initial route selection keeps the format router interaction, but its visual treatment becomes more grid-like and technical.

After a route is selected:

- Top bar becomes a compact masthead with route state and glossary.
- Format picker becomes a left navigation rail.
- Main workbench uses two primary columns:
  - Command panel: upload, route-specific parameters, advanced options, run actions.
  - Execution panel: job state, logs, result artifact, PDF preview.
- Diagnostics remain explicit and visible near the active route state.

## Visual System

- Background: white and light gray surfaces, no decorative gradients.
- Accent: IBM Blue-style primary action and focus color.
- Borders: hairline gray dividers and bottom-border inputs.
- Radius: mostly `0`, with small radius only where existing drag targets need touch clarity.
- Shadows: removed except temporary drag proxies and focused overlays.
- Typography: system sans in compact sizes; monospace only for logs.

## Interaction

- Preserve route selection, pointer drag, slot drag, and route morph behavior.
- Keep all controls reachable on mobile.
- Use clear focus states and avoid hover-only affordances.
- Preserve current reduced-motion handling.

## Verification

- Update existing frontend string/CSS tests to assert Carbon workbench tokens and layout.
- Run the frontend/backend test suite.
- Run the app locally and inspect the route-selected view in browser.
