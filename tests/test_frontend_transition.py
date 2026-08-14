import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class FrontendTransitionTests(unittest.TestCase):
    def test_route_transition_structure_and_state_hooks_exist(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('class="conversion-page"', html)
        self.assertIn(".conversion-page", css)
        self.assertIn(".shell.is-route-active", css)
        self.assertIn(".shell.is-route-entering", css)
        self.assertIn(".shell.is-route-active .format-orbit", css)
        self.assertIn(".format-node.is-settling", css)
        self.assertIn("prefers-reduced-motion: reduce", css)
        self.assertIn('classList.add("is-route-active")', js)
        self.assertIn('classList.add("is-route-entering")', js)
        self.assertIn('classList.remove("is-route-active")', js)
        self.assertIn('classList.remove("is-route-entering")', js)
        self.assertIn("ROUTE_ENTER_DELAY_MS", js)
        self.assertIn("ROUTE_ANIMATION_MS", js)
        self.assertIn("formatOrbit.addEventListener", js)
        self.assertIn("document.elementsFromPoint", js)

    def test_route_transition_does_not_animate_layout_properties(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")
        transition_lines = [
            line.strip()
            for line in css.splitlines()
            if line.strip().startswith("transition:")
        ]

        for line in transition_lines:
            self.assertNotIn("grid-template-columns", line)
            self.assertNotIn("min-height", line)
            self.assertNotIn("max-height", line)

    def test_orbit_decorative_layers_do_not_intercept_clicks(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")

        self.assertIn(".format-orbit::after", css)
        self.assertIn("pointer-events: none", css[css.index(".format-orbit::after"):css.index(".orbit-ring")])

    def test_format_drop_slots_drive_route_selection(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('class="route-slots"', html)
        self.assertIn('data-route-slot="source"', html)
        self.assertIn('data-route-slot="target"', html)
        self.assertIn('draggable="false"', html)
        self.assertIn(".route-slot", css)
        self.assertIn(".route-slot.is-drag-over", css)
        self.assertIn(".route-slot.is-filled", css)
        self.assertIn("routeSlots", js)
        self.assertIn("assignFormatToSlot", js)

    def test_format_nodes_and_center_slots_are_visually_minimal(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertNotIn("node-kind", html)
        self.assertNotIn("拖入源格式", html)
        self.assertNotIn("拖入目标格式", html)
        self.assertNotIn("拖入源格式", js)
        self.assertNotIn("拖入目标格式", js)

    def test_format_modules_use_pointer_drag_for_normal_mouse_dragging(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn("pointerDragState", js)
        self.assertIn("pointerdown", js)
        self.assertIn("pointermove", js)
        self.assertIn("pointerup", js)
        self.assertIn("suppressNextNodeClick", js)
        self.assertIn("CLICK_SUPPRESS_MS", js)
        self.assertIn("shouldSuppressSyntheticClick", js)
        self.assertIn("stopImmediatePropagation", js)
        self.assertIn("}, true);", js)
        self.assertIn("createDragProxy", js)
        self.assertIn("finishPointerDrag", js)
        self.assertIn(".drag-proxy", css)
        self.assertIn(".format-node.is-pointer-dragging", css)

    def test_filled_route_slots_can_be_pointer_dragged(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn("slotDragState", js)
        self.assertIn("startSlotDrag", js)
        self.assertIn("finishSlotDrag", js)
        self.assertIn("createSlotDragProxy", js)
        self.assertIn('slot.addEventListener("pointerdown"', js)
        self.assertIn("getBoundingClientRect", js)
        self.assertIn("is-slot-dragging", js)
        self.assertIn(".route-slot.is-slot-dragging", css)
        self.assertIn(".route-slot.is-filled", css)

    def test_dragging_filled_slot_to_another_filled_slot_swaps_formats(self):
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn("swapFilledSlots", js)
        self.assertIn('targetSlot.classList.contains("is-filled")', js)
        self.assertIn("sourceFormat = targetFormat", js)
        self.assertIn("targetFormat = previousSource", js)

    def test_dragging_filled_slot_to_empty_slot_moves_without_duplication(self):
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn("moveFilledSlotToEmptySlot", js)
        self.assertIn("clearDraggedSlot", js)
        self.assertIn("sourceFormat = null", js)
        self.assertIn("targetFormat = null", js)
        finish_slot_block = js[js.index("function finishSlotDrag"):js.index("function endSlotDrag")]
        self.assertIn("moveFilledSlotToEmptySlot(slotName, targetSlot.dataset.routeSlot, format)", finish_slot_block)
        self.assertNotIn("assignFormatToSlot(targetSlot.dataset.routeSlot, format)", finish_slot_block)

    def test_format_drag_has_single_visible_module_source(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn("is-assigned", js)
        self.assertIn(".format-node.is-assigned", css)
        assigned_block = css[css.index(".format-node.is-assigned"):css.index(".shell.is-route-active .format-node.is-assigned")]
        self.assertIn("opacity: 0", assigned_block)
        self.assertIn("pointer-events: none", assigned_block)
        self.assertIn("opacity: 0", css[css.index(".format-node.is-pointer-dragging"):css.index(".drag-proxy")])
        self.assertNotIn('node.addEventListener("dragstart"', js)
        self.assertNotIn('slot.addEventListener("drop"', js)

    def test_format_nodes_do_not_animate_orbit_transform_while_selecting(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")
        format_node_block = css[css.index("\n.format-node {"):css.index("\n.format-node::before")]
        settling_block = css[css.index(".format-node.is-settling"):css.index(".node-code")]

        self.assertNotIn("transform", format_node_block[format_node_block.index("transition:"):])
        self.assertNotIn("scale", settling_block)
        self.assertNotIn("rotate", settling_block)

    def test_unavailable_target_nodes_are_dimmed_after_single_selection(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn("routeAvailabilityForCandidate", js)
        self.assertIn("is-route-unavailable", js)
        self.assertIn("resolveRoute(sourceFormat, candidate)", js)
        self.assertIn("resolveRoute(candidate, targetFormat)", js)
        self.assertIn(".format-node.is-route-unavailable", css)
        unavailable_block = css[css.index(".format-node.is-route-unavailable"):css.index(".format-node.is-route-unavailable:hover")]
        self.assertIn("opacity:", unavailable_block)
        self.assertIn("border-width: 2px", unavailable_block)
        self.assertIn("--node-scale: 0.86", unavailable_block)

    def test_format_dragging_suppresses_text_selection(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn("TEXT_SELECTION_CLASS", js)
        self.assertIn("is-format-dragging", js)
        self.assertIn("blockTextSelection", js)
        self.assertIn("unblockTextSelection", js)
        self.assertIn("removeAllRanges", js)
        self.assertIn("event.preventDefault();", js[js.index("function updatePointerDrag"):js.index("function updateSlotDrag")])
        self.assertIn("event.preventDefault();", js[js.index("function updateSlotDrag"):js.index("function endPointerDrag")])
        self.assertIn("body.is-format-dragging", css)
        drag_block = css[css.index("body.is-format-dragging"):css.index("button,")]
        self.assertIn("-webkit-user-select: none", drag_block)
        self.assertIn("user-select: none", drag_block)

    def test_filled_route_slots_can_be_cleared_and_adjusted_without_replaying_main_transition(self):
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn("clearFormatSlot", js)
        self.assertIn("reuseOppositeSlotFormat", js)
        self.assertIn("hasOpenedRoutePage", js)
        self.assertIn("updateRoutePageWithoutTransition", js)
        self.assertIn('slot.addEventListener("click"', js)
        self.assertIn('slot.classList.contains("is-filled")', js)
        self.assertIn('slot.classList.contains("can-reuse-format")', js)

    def test_filled_route_slots_have_hover_and_focus_affordance(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")

        self.assertIn(".route-slot.is-filled:hover", css)
        self.assertIn(".route-slot.is-filled:focus-visible", css)
        hover_block = css[css.index(".route-slot.is-filled:hover"):css.index(".slot-label")]
        self.assertIn("cursor: pointer", hover_block)
        self.assertIn("scale(1.028)", hover_block)
        self.assertIn("box-shadow", hover_block)
        self.assertIn("filter: saturate", hover_block)

    def test_pdf_to_chinese_pdf_translation_route_is_available(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('data-format="translated_pdf"', html)
        self.assertIn("中文PDF", html)
        self.assertIn("pdf_translate", js)
        self.assertIn("capabilityRoutes.find", js)
        self.assertNotIn('source === "pdf" && target === "translated_pdf"', js)
        self.assertNotIn("routeCopy.pdf_translate", js)
        self.assertNotIn('accept: formats.pdf.input', js)

    def test_pdf_and_image_to_ocr_route_is_available(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('data-format="ocr"', html)
        self.assertIn("ocr", js)
        self.assertIn("routePanels.includes(panel)", js)
        self.assertIn('option value="ocr"', html)
        self.assertNotIn('target === "ocr"', js)
        self.assertNotIn('["pdf", "image"].includes(source)', js)
        self.assertNotIn('panel === "ocr" && kind.value === "ocr"', js)

    def test_data_format_node_routes_to_markdown_and_pdf(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('data-format="data"', html)
        self.assertIn("Data", html)
        self.assertIn("capabilityFormats", js)
        self.assertNotIn("data:", js)

    def test_translation_defaults_and_panels_remain_wired(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('<option value="deepseek">DeepSeek</option>', html)
        self.assertIn('<option value="translated">纯译文 PDF</option>', html)
        self.assertIn('<input id="sourceLang" value="en" />', html)
        self.assertIn('<input id="targetLang" value="zh" />', html)
        self.assertIn("routePanels.includes(panel)", js)
        self.assertNotIn('panel === "translate" && kind.value === "pdf_translate"', js)
        self.assertNotIn('id="pages"', html)
        self.assertNotIn('pages: value("#pages")', js)

    def test_translation_glossary_is_top_right_and_persistent(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('class="topbar-glossary translation-glossary"', html)
        self.assertIn('id="glossary"', html[html.index('<div class="topbar-right">'):html.index("</header>")])
        self.assertNotIn('id="glossary"', html[html.index('<form id="jobForm"'):html.index("</form>")])
        self.assertNotIn('id="providerStatus"', html)
        self.assertIn(".topbar-glossary", css)
        self.assertNotIn(".control-strip .translation-glossary", css)
        self.assertIn("position: absolute", css[css.index(".topbar-glossary:focus-within textarea"):css.index(".route-reset")])
        self.assertIn("providerStatus) {", js)
        self.assertIn("GLOSSARY_STORAGE_KEY", js)
        self.assertIn("loadStoredGlossary", js)
        self.assertIn("saveStoredGlossary", js)
        self.assertIn("localStorage", js)

    def test_static_assets_are_versioned_after_drag_runtime_changes(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")

        self.assertIn("/static/styles.css?v=workbench-4", html)
        self.assertIn("/static/app.js?v=workbench-4", html)

    def test_diagnostics_surface_is_wired_to_route_panel_and_submit_gate(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('id="diagnosticsList"', html)
        self.assertIn(".diagnostics-list", css)
        self.assertIn("loadDiagnostics", js)
        self.assertIn('fetch("/api/diagnostics")', js)
        self.assertIn("dependenciesForRoute", js)
        self.assertIn("missingRequiredDependencies", js)
        self.assertIn("diagnosticsReady", js)
        self.assertIn("submitButton.disabled = !canSubmit", js)
        self.assertIn("install_hint", js)

    def test_frontend_loads_routes_from_capabilities_endpoint(self):
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('fetch("/api/capabilities")', js)
        self.assertIn("capabilityRoutes", js)
        self.assertIn("capabilityFormats", js)
        self.assertIn("loadCapabilities", js)
        self.assertNotIn("const formats =", js)
        self.assertNotIn("const routeCopy =", js)
        self.assertNotIn("capabilitiesReady", js)
        self.assertIn("能力加载失败", js)

    def test_frontend_preflight_blocks_submit_with_server_issues(self):
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('fetch("/api/preflight"', js)
        self.assertIn("blocking_issues", js)
        self.assertIn("preflightResult", js)
        self.assertIn("renderPreflight", js)

    def test_frontend_restores_most_recent_job_after_refresh(self):
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn("LAST_JOB_STORAGE_KEY", js)
        self.assertIn("restoreLastJob", js)
        self.assertIn("localStorage.setItem(LAST_JOB_STORAGE_KEY", js)
        self.assertIn("localStorage.removeItem(LAST_JOB_STORAGE_KEY", js)

    def test_advanced_options_start_collapsed_and_expand_only_when_relevant(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('id="advancedToggle"', html)
        self.assertIn("advancedCollapsed", js)
        self.assertIn("routeHasAdvancedOptions", js)

    def test_pdf_and_image_to_markdown_send_ocr_fallback_options(self):
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn("ocrFallback", js)
        self.assertIn("ocr_fallback", js)
        self.assertIn("ocr_language", js)
        self.assertIn("activeRoute?.ocrFallback", js)
        self.assertNotIn('target === "md" && ["pdf", "image"].includes(source)', js)

    def test_pdf_edit_reorder_and_crop_options_are_wired(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('id="reorderPages"', html)
        self.assertIn('id="cropPages"', html)
        self.assertIn('id="cropBox"', html)
        self.assertIn('reorder_pages: value("#reorderPages")', js)
        self.assertIn('crop_pages: value("#cropPages")', js)
        self.assertIn('crop_box: value("#cropBox")', js)

    def test_conversion_page_uses_precision_deck_structure(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")

        for class_name in (
            "precision-rail",
            "command-deck",
            "file-well",
            "control-strip",
            "execution-deck",
            "console-pane",
            "artifact-pane",
            "filmstrip-pane",
        ):
            self.assertIn(class_name, html)
            self.assertIn(f".{class_name}", css)

        self.assertIn("/static/styles.css?v=workbench-4", html)
        self.assertIn("/static/app.js?v=workbench-4", html)

    def test_document_workbench_tokens_exist(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")

        self.assertIn("--paper: #f4f6f3", css)
        self.assertIn("--panel: #fbfcf9", css)
        self.assertIn("--accent: #b3482d", css)
        self.assertIn("--radius: 6px", css)
        self.assertIn("background-size: 32px 32px", css)

    def test_hidden_conversion_page_does_not_push_initial_compass_down(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")

        hidden_page_block = css[css.index(".conversion-page {"):css.index(".conversion-page .route-panel")]
        active_page_block = css[css.index(".shell.is-route-active .conversion-page {"):css.index(".shell.is-route-active .conversion-page .route-panel")]

        self.assertIn("position: absolute", hidden_page_block)
        self.assertIn("position: relative", active_page_block)

    def test_active_compass_stays_centered_in_left_viewport(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")

        active_orbit_block = css[css.index(".shell.is-route-active .format-orbit {"):css.index(".shell.is-route-active .conversion-page {")]

        self.assertIn("position: sticky", active_orbit_block)
        self.assertIn("top: clamp", active_orbit_block)
        self.assertIn("align-self: start", active_orbit_block)

    def test_route_entry_uses_original_orbit_transition(self):
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn("ROUTE_ENTER_DELAY_MS = 180", js)
        self.assertIn("ROUTE_ANIMATION_MS = 900", js)
        self.assertNotIn("routeMorphProxy", js)

    def test_active_conversion_deck_is_compact_enough_for_first_viewport(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")

        active_router_block = css[css.index(".shell.is-route-active .router {"):css.index(".format-orbit {")]
        active_page_block = css[css.index(".shell.is-route-active .conversion-page {"):css.index(".shell.is-route-active .workspace {")]
        workspace_block = css[css.index(".shell.is-route-active .workspace {"):css.index(".precision-rail,")]
        rail_block = css[css.index(".precision-rail {"):css.index(".precision-rail .route-panel-head")]
        file_well_block = css[css.index(".file-well {"):css.index(".file-well::before,")]
        execution_start = css.index(".execution-deck {")
        console_start = css.index(".console-pane pre {")
        execution_block = css[execution_start:css.index(".execution-grid", execution_start)]
        console_block = css[console_start:css.index(".artifact-pane", console_start)]
        preview_start = css.rindex(".preview:empty {")
        diagnostic_start = css.rindex(".diagnostic-item small {")
        preview_block = css[preview_start:css.index(".preview img", preview_start)]
        diagnostic_block = css[diagnostic_start:css.index(".command-deck", diagnostic_start)]

        self.assertIn("grid-template-columns: minmax(300px, 360px) minmax(0, 1fr)", active_router_block)
        self.assertIn("grid-template-columns: minmax(0, 1fr)", active_page_block)
        self.assertIn("grid-template-columns: minmax(320px, 0.92fr) minmax(380px, 1.08fr)", workspace_block)
        self.assertIn("min-height: 0", rail_block)
        self.assertIn("min-height: 132px", file_well_block)
        self.assertIn("min-height: 0", execution_block)
        self.assertIn("min-height: 0", console_block)
        self.assertIn("max-height: none", console_block)
        self.assertIn("min-height: 100%", preview_block)
        self.assertIn("display: none", diagnostic_block)

    def test_active_route_rail_is_removed_from_visible_layout(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")

        self.assertIn('id="resetRoute"', html[html.index('<div class="topbar-right">'):html.index("</header>")])
        self.assertNotIn('id="resetRoute"', html[html.index('<aside class="route-panel'):html.index("</aside>")])
        active_route_panel_block = css[css.index(".shell.is-route-active .conversion-page .route-panel {"):css.index(".shell.is-route-active .conversion-page .input-panel")]
        route_reset_block = css[css.index(".route-reset {"):css.index(".shell.is-route-active .route-reset")]
        active_route_reset_block = css[css.index(".shell.is-route-active .route-reset {"):css.index("h1,")]

        self.assertIn("display: none", active_route_panel_block)
        self.assertIn("display: none", route_reset_block)
        self.assertIn("display: inline-flex", active_route_reset_block)

    def test_active_conversion_deck_stretches_to_fill_right_side(self):
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")

        active_page_block = css[css.index(".shell.is-route-active .conversion-page {"):css.index(".shell.is-route-active .workspace {")]
        workspace_block = css[css.index(".shell.is-route-active .workspace {"):css.index(".shell.is-route-active .input-panel")]
        active_panels_block = css[css.index(".shell.is-route-active .input-panel,"):css.index(".precision-rail,")]
        command_block = css[css.index(".command-deck {"):css.index(".command-deck .panel-head")]
        execution_block = css[css.index(".execution-deck {"):css.index(".execution-grid")]
        filmstrip_block = css[css.index(".filmstrip-pane {"):css.index(".preview {", css.index(".filmstrip-pane {"))]

        self.assertIn("align-items: stretch", active_page_block)
        self.assertIn("min-height: calc(100vh - 158px)", active_page_block)
        self.assertIn("align-items: stretch", workspace_block)
        self.assertIn("align-self: stretch", active_panels_block)
        self.assertIn("height: 100%", active_panels_block)
        self.assertIn("grid-template-rows: auto minmax(180px, 1fr) auto auto auto", command_block)
        self.assertIn("grid-template-rows: auto minmax(118px, 0.8fr) minmax(122px, 1fr)", execution_block)
        self.assertIn("grid-template-rows: auto minmax(0, 1fr)", filmstrip_block)


if __name__ == "__main__":
    unittest.main()
