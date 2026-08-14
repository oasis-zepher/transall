from __future__ import annotations

import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]


class BrowserUiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        from playwright.sync_api import sync_playwright

        cls._temporary_data = tempfile.TemporaryDirectory()
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            cls.port = listener.getsockname()[1]
        cls.base_url = f"http://127.0.0.1:{cls.port}"
        environment = os.environ.copy()
        environment["DOCWORK_DATA_DIR"] = cls._temporary_data.name
        cls.server = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "uvicorn",
                "app.main:app",
                "--host",
                "127.0.0.1",
                "--port",
                str(cls.port),
                "--log-level",
                "warning",
            ],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if cls.server.poll() is not None:
                cls._stop_server()
                raise RuntimeError("UI test server exited before becoming ready")
            try:
                with urlopen(cls.base_url, timeout=0.5) as response:
                    if response.status == 200:
                        break
            except OSError:
                time.sleep(0.1)
        else:
            cls._stop_server()
            raise RuntimeError("UI test server did not become ready")

        cls.playwright = sync_playwright().start()
        try:
            cls.browser = cls.playwright.chromium.launch()
        except Exception as exc:
            cls.playwright.stop()
            cls._stop_server()
            raise RuntimeError("Playwright Chromium is not installed") from exc

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "browser"):
            cls.browser.close()
        if hasattr(cls, "playwright"):
            cls.playwright.stop()
        cls._stop_server()

    @classmethod
    def _stop_server(cls) -> None:
        server = getattr(cls, "server", None)
        if server is not None and server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
        temporary_data = getattr(cls, "_temporary_data", None)
        if temporary_data is not None:
            temporary_data.cleanup()

    def open_page(self, width: int, height: int = 900):
        page = self.browser.new_page(viewport={"width": width, "height": height})
        page.goto(self.base_url, wait_until="networkidle")
        return page

    def activate_conversion_route(self, page) -> None:
        page.wait_for_timeout(500)
        for format_name in ("word", "pdf"):
            node = page.locator(f'.format-node[data-format="{format_name}"]')
            box = node.bounding_box()
            self.assertIsNotNone(box)
            page.mouse.click(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
            page.wait_for_timeout(80)
        page.locator(".shell.is-route-active").wait_for(timeout=4_000)
        page.locator(".conversion-page").wait_for(state="visible", timeout=4_000)
        page.wait_for_function("getComputedStyle(document.querySelector('#jobForm')).opacity === '1'", timeout=4_000)

    def test_active_workspace_has_no_horizontal_overflow_at_supported_widths(self):
        for width in (375, 768, 980):
            with self.subTest(width=width):
                page = self.open_page(width)
                try:
                    self.activate_conversion_route(page)
                    geometry = page.evaluate(
                        """() => ({
                          viewport: window.innerWidth,
                          documentWidth: document.documentElement.scrollWidth,
                          workspaceWidth: document.querySelector('.workspace').getBoundingClientRect().width,
                          workspaceColumns: getComputedStyle(document.querySelector('.workspace')).gridTemplateColumns,
                        })"""
                    )
                    self.assertLessEqual(geometry["documentWidth"], geometry["viewport"])
                    self.assertLessEqual(geometry["workspaceWidth"], geometry["viewport"])
                    self.assertNotIn("440px", geometry["workspaceColumns"])
                finally:
                    page.close()

    def test_upload_focus_and_accessible_names_are_exposed(self):
        page = self.open_page(375)
        try:
            source_slot = page.locator('[data-route-slot="source"]')
            target_slot = page.locator('[data-route-slot="target"]')
            self.assertEqual(source_slot.locator(".slot-label").inner_text(), "源格式")
            self.assertEqual(target_slot.locator(".slot-label").inner_text(), "目标格式")
            self.assertIn("源格式", source_slot.get_attribute("aria-label"))
            self.assertIn("目标格式", target_slot.get_attribute("aria-label"))

            self.activate_conversion_route(page)
            files = page.locator("#files")
            files.focus()
            focus_state = page.evaluate(
                """() => ({
                  focused: document.activeElement === document.querySelector('#files'),
                  shadow: getComputedStyle(document.querySelector('#dropzone')).boxShadow,
                  label: document.querySelector('#files').getAttribute('aria-labelledby'),
                })"""
            )
            self.assertTrue(focus_state["focused"])
            self.assertNotEqual(focus_state["shadow"], "none")
            self.assertEqual(focus_state["label"], "slotTitle slotHint")

            progress = page.locator("#progressTrack")
            self.assertEqual(progress.get_attribute("role"), "progressbar")
            self.assertEqual(progress.get_attribute("aria-valuemin"), "0")
            self.assertEqual(progress.get_attribute("aria-valuemax"), "100")
        finally:
            page.close()


if __name__ == "__main__":
    unittest.main()
