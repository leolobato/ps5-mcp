"""Install onto the console: ELF payloads into Payload Manager (port 8084), packages through PS5 Web File Manager (8888).

- `.elf`: uploaded to Payload Manager's library (`/manage:upload`), the same way `padd start` deploys padd, and run
  once with `/loadpayload:` when asked.
- `.pkg`: uploaded to `PKG_DIR` with Web File Manager's upload task, then installed with `/api/install-pkg`. The
  console installs from that file, so it stays there; delete it from the console once the install is done.

Web File Manager runs one task at a time (docs/findings.md): every step here waits for its task to finish.
"""

from __future__ import annotations

import contextlib
import http.client
import json
import time
import urllib.parse
from collections.abc import Callable
from pathlib import Path

from .probe_runner import Console

PKG_DIR = "/data/ps5-mcp/pkg"
CHUNK = 1 << 20

Progress = Callable[[str], None]


def install(host: str, path: Path, run: bool = False, progress: Progress = print, timeout: float = 3600) -> str:
    """Installs `path` (.elf or .pkg) and returns a one-line summary."""
    path = Path(path).expanduser()
    if not path.is_file():
        raise ValueError(f"{path} is not a file")
    suffix = path.suffix.lower()
    if suffix == ".elf":
        return install_elf(host, path, run, progress)
    if suffix == ".pkg":
        if run:
            raise ValueError("run applies to .elf payloads only")
        return install_pkg(host, path, progress, timeout)
    raise ValueError(f"{path.name}: only .elf payloads and .pkg packages can be installed")


def install_elf(host: str, path: Path, run: bool, progress: Progress) -> str:
    console = Console(host)
    raw = path.read_bytes()
    progress(f"uploading {path.name} ({len(raw)} bytes) to Payload Manager")
    console.request(8084, "/manage:upload", {"filename": path.name}, raw, {"Content-Type": "application/octet-stream"})
    payloads = json.loads(console.request(8084, "/list_payloads", method="GET"))["payloads"]
    matches = [p for p in payloads if p.endswith("/" + path.name)]
    if len(matches) != 1:
        raise RuntimeError(f"Payload Manager lists {len(matches)} payloads named {path.name}: {matches}")
    if not run:
        return f"installed {path.name} in Payload Manager as {matches[0]}"
    progress(f"running {matches[0]}")
    console.request(8084, "/loadpayload:" + urllib.parse.quote(matches[0], safe="/"), method="GET")
    return f"installed and started {path.name} ({matches[0]})"


def install_pkg(host: str, path: Path, progress: Progress, timeout: float) -> str:
    console = Console(host)
    size = path.stat().st_size
    free = _free_bytes(console, "/data")
    if free is not None and free < size * 2:  # the package and the installed copy
        raise RuntimeError(f"not enough space on the console: {size * 2 >> 20} MB needed, {free >> 20} MB free")
    console.ensure_dir(PKG_DIR)
    remote = f"{PKG_DIR}/{path.name}"
    _upload(console, host, path, PKG_DIR, progress, timeout)
    progress(f"installing {remote}")
    submitted = console.api("/api/install-pkg", {"paths": remote}, form=True)
    task_ids = submitted.get("task_ids", [submitted.get("task_id")])
    if (not isinstance(task_ids, list) or len(task_ids) != 1
            or type(task_ids[0]) is not int or task_ids[0] <= 0):
        raise RuntimeError(f"install of {path.name} unverified: no unambiguous task id ({task_ids!r}); "
                           "outcome unknown, check the console before retrying")
    task_id = task_ids[0]
    task = _wait(console, "pkg_install", timeout, progress, task_id)
    if task.get("state") != "done":
        raise RuntimeError(f"install of {path.name} {task.get('state', 'unknown')}: {_task_error(task)}")
    return f"installed {path.name} (the package stays at {remote})"


def _free_bytes(console: Console, path: str) -> int | None:
    try:
        spaces = console.api("/api/space", {"path": path})["spaces"]
    except Exception:  # noqa: BLE001 - only a pre-check; the upload reports the real error
        return None
    return next((s["free"] for s in spaces if s.get("path") == path), None)


def _upload(console: Console, host: str, path: Path, directory: str, progress: Progress, timeout: float,
            name: str | None = None) -> None:
    """One file through Web File Manager's upload task: prepare, stream the bytes, finish. `name` renames it."""
    size = path.stat().st_size
    name = name or path.name
    task = console.api("/api/upload/prepare", {"path": directory, "src": name, "total": size, "count": 1,
                                               "rels": name, "sizes": size, "overwrite": "1"}, form=True)
    task_id = task.get("task_id")
    if type(task_id) is not int or task_id <= 0:
        raise RuntimeError(f"upload of {name} unverified: invalid task id ({task_id!r}); "
                           "outcome unknown, check the console before retrying")
    try:
        connection = http.client.HTTPConnection(host, 8888, timeout=60)
        connection.putrequest("POST", "/api/upload-file")
        for header, value in {"Content-Type": "application/octet-stream", "Content-Length": str(size),
                            "X-WFM-Task-ID": str(task_id), "X-WFM-Path": urllib.parse.quote(directory, safe=""),
                            "X-WFM-Rel": urllib.parse.quote(name, safe=""), "X-WFM-Size": str(size),
                            "X-WFM-Overwrite": "1"}.items():
            connection.putheader(header, value)
        connection.endheaders()
        sent, shown = 0, 0.0
        with path.open("rb") as source:
            while chunk := source.read(CHUNK):
                connection.send(chunk)
                sent += len(chunk)
                if time.monotonic() - shown > 2 or sent == size:
                    shown = time.monotonic()
                    progress(f"uploading {name}: {sent * 100 // max(size, 1)}% of {size >> 20} MB")
        response = connection.getresponse()
        body = response.read()
        connection.close()
        if not 200 <= response.status < 300:
            raise RuntimeError(f"upload of {name} failed: HTTP {response.status} {body[:200]!r}")
    except BaseException:
        for step in ("/api/cancel", "/api/upload/finish"):  # free Web File Manager's only task slot
            with contextlib.suppress(Exception):  # the task may already be terminal
                console.api(step, {"id" if step == "/api/cancel" else "task_id": task_id})
        raise
    console.api("/api/upload/finish", {"task_id": task_id})
    task = _wait(console, "upload", timeout, progress, task_id)
    if task.get("state") != "done":
        raise RuntimeError(f"upload of {name} {task.get('state', 'unknown')}: {_task_error(task)}")


def _wait(console: Console, op: str, timeout: float, progress: Progress, task_id: int | None = None) -> dict:
    """Return a confirmed terminal task, never infer success from a missing task.

    Prefer the submitted id; otherwise latch onto the newest task of `op`. Web File Manager's upload
    `completion` records are success-only and omit `state`, so a matching record confirms that upload.
    Package installs need an explicit terminal state. Unknown outcomes raise rather than report success.
    """
    start = time.monotonic()
    seen: dict = {}
    shown = ""
    while time.monotonic() - start < timeout:
        data = console.api("/api/tasks")
        expected_id = task_id if task_id is not None else seen.get("id")
        matches = [t for t in data.get("tasks", [])
                   if t.get("op") == op and (expected_id is None or t.get("id") == expected_id)]
        if matches:
            seen = matches[0]  # Web File Manager prepends new tasks.
            if seen.get("state") in ("done", "failed", "canceled"):
                return seen
            line = f"{op}: {seen.get('state')} {seen.get('current') or ''}".strip()
            if line != shown:
                shown = line
                progress(line)
        completion = data.get("completion") or {}
        expected_id = task_id if task_id is not None else seen.get("id")
        if expected_id is not None and completion.get("id") == expected_id and completion.get("op") == op:
            state = completion.get("state")
            if state in ("done", "failed", "canceled"):
                return completion
            if op == "upload" and state is None:
                return {**completion, "state": "done"}
        if seen and not matches:
            raise RuntimeError(f"{op} task {expected_id} disappeared without a confirmed completion; "
                               "outcome unknown, check the console before retrying")
        if not seen and time.monotonic() - start >= 15:
            raise TimeoutError(f"{op} task was not observed within 15 s; outcome unknown, "
                               "check the console before retrying")
        time.sleep(min(1, max(0, timeout - (time.monotonic() - start))))
    raise TimeoutError(f"{op} did not finish within {timeout:.0f} s; outcome unknown, "
                       "check the console before retrying")


def _task_error(task: dict) -> str:
    return str(task.get("error") or task.get("error_code") or task.get("current") or "no details")
