"""Console transport and deployment helpers shared by padd lifecycle and MCP app listing."""

from __future__ import annotations

import hashlib
import json
import subprocess
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

from . import capture

ROOT = Path(__file__).resolve().parents[2]


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
        with self.opener.open(req, timeout=10) as response:
            return response.read()

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
