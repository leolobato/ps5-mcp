"""Platform selection for the shared local capture/controller service."""
from __future__ import annotations

import os
import sys
from pathlib import Path

from . import capture

Backend = capture.Service


def selected() -> str:
    """"linux" (the Python hub) or "native" (the macOS app): PS5MCP_BACKEND, else the platform's own."""
    return os.environ.get("PS5MCP_BACKEND") or ("linux" if sys.platform == "linux" else "native")


def console_allowed() -> bool:
    """The Linux hub stays offline unless PS5MCP_ALLOW_CONSOLE=1; the macOS app always talks to the console."""
    return selected() != "linux" or os.environ.get("PS5MCP_ALLOW_CONSOLE") == "1"


def select(root: Path | None = None, name: str | None = None) -> Backend:
    name = name or selected()
    if name == "linux":
        from .linux.backend import LinuxHub
        return LinuxHub(root)
    if name == "native":
        return capture.NativeApp(root)
    raise capture.CaptureError(f"Unsupported hub backend: {name}; choose linux or native")
