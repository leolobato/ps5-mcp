"""Console transport and deployment helpers shared by padd lifecycle and MCP app listing."""

from __future__ import annotations

import errno
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

from . import capture

ROOT = Path(__file__).resolve().parents[2]
SERVICES = {8084: "Payload Manager", 8888: "PS5 Web File Manager"}
STARTERS = {8888: "Payload Manager can load it"}


class ConsoleError(OSError):
    """A console service could not be reached; the message names the service and what to do about it."""


def local_network_hint() -> str:
    python = sys.executable
    if (real := os.path.realpath(python)) != python:  # a venv links to the interpreter macOS actually sees
        python += f" → {real}"
    return (f"macOS Local Network privacy may be blocking this Python ({python}) even though other "
            "apps reach the console: allow it in System Settings › Privacy & Security › Local Network (it can "
            "be listed under the terminal or app that started it), then retry")


def unreachable(host: str, port: int, exc: BaseException) -> ConsoleError:
    """`exc` (a connection failure to host:port) as a message naming the service and the likely fix."""
    reason = exc.reason if isinstance(exc, urllib.error.URLError) else exc
    service = SERVICES.get(port, "Console service")
    code = getattr(reason, "errno", None)
    if code == errno.ECONNREFUSED:
        start = f"; start it ({STARTERS[port]})" if port in STARTERS else "; start it"
        return ConsoleError(f"{service} is not running on {host}:{port}{start}")
    if code == errno.EHOSTUNREACH:
        return ConsoleError(f"{service} at {host}:{port}: no route to host. {local_network_hint()}")
    if isinstance(reason, TimeoutError):
        return ConsoleError(f"{service} at {host}:{port} did not answer in time; is the console on?")
    return ConsoleError(f"{service} at {host}:{port} is unreachable: {reason}")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Console:
    def __init__(self, host: str):
        self.host = host
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self, port, path, params=None, data=None, headers=None, method="POST") -> bytes:
        if params:
            path += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(f"http://{self.host}:{port}{path}", data=data,
                                     headers=headers or {}, method=method)
        try:
            with self.opener.open(req, timeout=10) as response:
                return response.read()
        except urllib.error.HTTPError:
            raise  # the service answered
        except (urllib.error.URLError, OSError) as exc:
            raise unreachable(self.host, port, exc) from exc

    def api(self, path, params=None, form=False) -> dict:
        if form:
            raw = self.request(8888, path, data=urllib.parse.urlencode(params).encode(),
                               headers={"Content-Type": "application/x-www-form-urlencoded"})
        else:
            raw = self.request(8888, path, params)
        result = json.loads(raw)
        if not result.get("ok"):
            raise RuntimeError(result)
        return result

    def download(self, path: str) -> bytes:
        task = self.api("/api/download/prepare", {"paths": path}, form=True)
        return self.request(8888, "/api/download", {"id": task["task_id"]}, method="GET")

    def listdir(self, path: str) -> list[dict]:
        return self.api("/api/list", {"path": path})["entries"]

    def ensure_dir(self, path: str) -> None:
        parts = [p for p in path.split("/") if p]
        for i in range(1, len(parts)):
            parent, name = "/" + "/".join(parts[:i]), parts[i]
            if not any(e["name"] == name for e in self.listdir(parent)):
                self.api("/api/mkdir", {"path": parent, "name": name})


def _git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def _snapshot(out: Path, name: str, evidence: dict) -> None:
    try:
        path = capture.snapshot(out / f"{name}.png")
        evidence[f"snapshot_{name}"] = {"file": path.name, "sha256": digest(path.read_bytes()),
                                        "mean_luma": round(capture.mean_luma(path), 1),
                                        "taken_at": datetime.now(UTC).isoformat()}
    except Exception as exc:  # noqa: BLE001 - evidence gathering must not abort the run record.
        evidence[f"snapshot_{name}"] = {"error": str(exc)}
