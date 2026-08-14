# Carbon Workbench UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign transall's static frontend into an IBM Carbon-inspired local document workbench.

**Architecture:** Keep the current single-page static app and route-selection behavior. Replace the visual system in CSS, lightly adjust HTML class names and asset versions, and update frontend tests to lock the Carbon workbench tokens and layout.

**Tech Stack:** FastAPI static files, plain HTML/CSS/JavaScript, Python `unittest`.

---

## File Structure

- Modify `app/static/index.html`: add Carbon-oriented structural class names and bump static asset versions.
- Modify `app/static/styles.css`: replace the warm circular workbench skin with flat Carbon-like tokens, masthead, rail, panels, fields, logs, and responsive rules.
- Modify `app/static/app.js`: only bump timing/version hooks if needed; preserve route, drag, preflight, upload, preview, and job logic.
- Modify `tests/test_frontend_transition.py`: update assertions from the previous warm workbench to Carbon tokens and layout.

## Task 1: Lock Carbon Visual Contract

**Files:**
- Modify: `tests/test_frontend_transition.py`
- Modify: `app/static/index.html`
- Modify: `app/static/styles.css`

- [ ] **Step 1: Add frontend tests for Carbon tokens**

Add a test that reads `styles.css` and asserts:

```python
self.assertIn("--cds-blue-60: #0f62fe", css)
self.assertIn("--cds-gray-100: #161616", css)
self.assertIn("--cds-gray-10: #f4f4f4", css)
self.assertIn("border-radius: 0", css)
self.assertIn("IBM Carbon Workbench", css)
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
python -m unittest tests.test_frontend_transition.FrontendTransitionTests.test_carbon_workbench_tokens_exist -v
```

Expected: fail until CSS tokens are added.

- [ ] **Step 3: Add Carbon tokens and asset version**

In `styles.css`, add Carbon-like custom properties under `:root`. In `index.html`, change asset versions to `carbon-1`.

- [ ] **Step 4: Re-run the focused test**

Run the same command. Expected: pass.

## Task 2: Restyle Shell, Masthead, and Route Rail

**Files:**
- Modify: `app/static/styles.css`
- Modify: `tests/test_frontend_transition.py`

- [ ] **Step 1: Add tests for masthead and active route rail**

Assert the active router uses a left rail and flat surfaces:

```python
self.assertIn("grid-template-columns: 240px minmax(0, 1fr)", active_router_block)
self.assertIn("background: var(--cds-gray-100)", topbar_block)
self.assertIn("border-radius: 0", active_orbit_block)
self.assertIn("box-shadow: none", active_orbit_block)
```

- [ ] **Step 2: Implement masthead and rail CSS**

Update `.topbar`, `.shell`, `.router`, `.format-orbit`, `.format-node`, and active route selectors to use Carbon-like black masthead, white/gray body, 240px rail, and blue focus/active states.

- [ ] **Step 3: Verify tests**

Run:

```bash
python -m unittest tests.test_frontend_transition.FrontendTransitionTests.test_active_format_picker_becomes_compact_navigation_rail -v
```

Expected: pass.

## Task 3: Restyle Workbench Panels and Controls

**Files:**
- Modify: `app/static/styles.css`
- Modify: `tests/test_frontend_transition.py`

- [ ] **Step 1: Add tests for command and execution panels**

Assert:

```python
self.assertIn("grid-template-columns: minmax(320px, 0.78fr) minmax(460px, 1.22fr)", workspace_block)
self.assertIn("border-bottom: 2px solid var(--cds-gray-50)", input_block)
self.assertIn("font-family: ui-monospace", console_block)
self.assertNotIn("linear-gradient", file_well_block)
```

- [ ] **Step 2: Implement panel and form CSS**

Update `.panel`, `.command-deck`, `.execution-deck`, `.file-well`, `.control-strip`, `input`, `select`, `textarea`, `.actions`, `.console-pane`, `.artifact-pane`, and `.filmstrip-pane`.

- [ ] **Step 3: Verify focused tests**

Run:

```bash
python -m unittest tests.test_frontend_transition.FrontendTransitionTests.test_active_conversion_deck_is_compact_enough_for_first_viewport tests.test_frontend_transition.FrontendTransitionTests.test_active_conversion_deck_stretches_to_fill_right_side -v
```

Expected: pass.

## Task 4: Responsive and Full Verification

**Files:**
- Modify: `app/static/styles.css`
- Modify: `tests/test_frontend_transition.py`

- [ ] **Step 1: Update responsive CSS**

At tablet/mobile breakpoints, stack the rail, command panel, execution panel, logs, artifacts, and preview without hiding core actions.

- [ ] **Step 2: Run all tests**

Run:

```bash
python -m unittest discover -s tests -v
```

Expected: all tests pass.

- [ ] **Step 3: Run local server**

Run:

```bash
python -m uvicorn app.main:app --host 127.0.0.1 --port 8765
```

Expected: app serves at `http://127.0.0.1:8765`.

- [ ] **Step 4: Browser verify**

Open the app, select `PDF -> 中文PDF`, and verify:

- route rail remains usable
- upload well, parameters, logs, artifact, and preview fit the first viewport on desktop
- mobile viewport has no text overlap
- existing route animation and drag interactions still work
