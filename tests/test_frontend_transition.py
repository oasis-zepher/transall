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
        format_node_block = css[css.index(".format-node {"):css.index(".format-node::before")]
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
        self.assertIn("translated_pdf", js)
        self.assertIn("pdf_translate", js)
        self.assertIn('source === "pdf" && target === "translated_pdf"', js)
        self.assertIn("routeCopy.pdf_translate", js)
        self.assertIn('accept: formats.pdf.input', js)
        self.assertIn('kindLabel: "PDF 翻译"', js)

    def test_pdf_and_image_to_ocr_route_is_available(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('data-format="ocr"', html)
        self.assertIn("ocr", js)
        self.assertIn('kind: "ocr"', js)
        self.assertIn('target === "ocr"', js)
        self.assertIn('["pdf", "image"].includes(source)', js)
        self.assertIn('el.dataset.panel === "ocr" && kind.value === "ocr"', js)
        self.assertIn('option value="ocr"', html)

    def test_data_format_node_routes_to_markdown_and_pdf(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('data-format="data"', html)
        self.assertIn("Data", html)
        self.assertIn("data:", js)
        self.assertIn(".csv,.json,.xml", js)
        self.assertIn("文本、表格、结构化数据或归档文件", js)

    def test_translation_defaults_and_panels_remain_wired(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('<option value="deepseek">DeepSeek</option>', html)
        self.assertIn('<option value="translated">纯译文 PDF</option>', html)
        self.assertIn('<input id="sourceLang" value="en" />', html)
        self.assertIn('<input id="targetLang" value="zh" />', html)
        self.assertIn('el.dataset.panel === "translate" && kind.value === "pdf_translate"', js)
        self.assertNotIn('id="pages"', html)
        self.assertNotIn('pages: value("#pages")', js)

    def test_translation_glossary_is_top_right_and_persistent(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")
        css = (ROOT / "app/static/styles.css").read_text(encoding="utf-8")
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('class="translation-glossary"', html)
        self.assertIn(".translation-glossary", css)
        self.assertIn("grid-column: 2", css[css.index(".translation-glossary"):css.index(".actions")])
        self.assertIn("GLOSSARY_STORAGE_KEY", js)
        self.assertIn("loadStoredGlossary", js)
        self.assertIn("saveStoredGlossary", js)
        self.assertIn("localStorage", js)

    def test_static_assets_are_versioned_after_drag_runtime_changes(self):
        html = (ROOT / "app/static/index.html").read_text(encoding="utf-8")

        self.assertIn("/static/styles.css?v=stability-1", html)
        self.assertIn("/static/app.js?v=stability-1", html)

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

    def test_pdf_and_image_to_markdown_send_ocr_fallback_options(self):
        js = (ROOT / "app/static/app.js").read_text(encoding="utf-8")

        self.assertIn('target === "md" && ["pdf", "image"].includes(source)', js)
        self.assertIn("ocrFallback", js)
        self.assertIn("ocr_fallback", js)
        self.assertIn("ocr_language", js)


if __name__ == "__main__":
    unittest.main()
