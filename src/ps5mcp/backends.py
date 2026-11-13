"""Platform selection for the shared local capture/controller service."""
from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Protocol

from . import capture


class Backend(Protocol):
    root: Path
    latest: Path
    socket: Path

    def start(self, **options) -> int: ...
    def stop(self, grace: float = 3) -> bool: ...
    def pid(self) -> int | None: ...
    def frame_age(self) -> float | None: ...
    def refresh(self) -> None: ...
    def show(self) -> None: ...
    def watch_change(self, threshold: float = 6, timeout: float = 2) -> tuple[float, dict]: ...


def select(root: Path | None = None, name: str | None = None) -> Backend:
    name = name or os.environ.get("PS5MCP_BACKEND") or ("linux" if sys.platform == "linux" else "native")
    if name == "linux":
        from .linux.backend import LinuxHub
        return LinuxHub(root)
    if name == "native":
        return capture.NativeApp(root)
    raise capture.CaptureError(f"Unsupported hub backend: {name}; choose linux or native")
