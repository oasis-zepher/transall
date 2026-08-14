from __future__ import annotations

import importlib.util
import shutil
from pathlib import Path
from typing import Any

from .engines import DEPENDENCY_DEFINITIONS
from .translation import load_provider_configs


def command_available(command: str) -> bool:
    return shutil.which(command) is not None


def python_module_available(module: str) -> bool:
    return importlib.util.find_spec(module) is not None


def playwright_chromium_available() -> bool:
    if not python_module_available("playwright"):
        return False
    try:
        from playwright.sync_api import sync_playwright

        with sync_playwright() as playwright:
            return Path(playwright.chromium.executable_path).is_file()
    except Exception:
        return False


def collect_diagnostics() -> dict[str, list[dict[str, Any]]]:
    providers = {provider["name"]: provider for provider in load_provider_configs(include_secrets=False)}
    dependencies = []
    for name, definition in DEPENDENCY_DEFINITIONS.items():
        availability = definition["availability"]
        availability_type = availability["type"]
        availability_name = availability["name"]
        if availability_type == "command":
            available = command_available(str(availability_name))
        elif availability_type == "python":
            available = python_module_available(str(availability_name))
        elif availability_type == "playwright_chromium":
            available = playwright_chromium_available()
        elif availability_type == "provider":
            available = bool(providers.get(str(availability_name), {}).get("configured"))
        else:
            available = False
        dependencies.append(
            {
                "name": name,
                "label": definition["label"],
                "available": available,
                "required_for": definition["required_for"],
                "detail": definition["detail"],
                "install_hint": definition["install_hint"],
                "category": definition["category"],
                "risk": definition["risk"],
                "license_note": definition.get("license_note", ""),
            }
        )
    return {"dependencies": dependencies}
