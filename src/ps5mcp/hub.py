"""Client of the PS5 app's local API (<state>/capture.sock, JSON lines; docs/app-api.md).

The app owns the capture card and the only padd connection. Every process that wants input (MCP servers, the
CLI) talks to it here, so they can all run at once. Requests carry an id; the reader thread routes replies by id
and pushed events (`subscribe`) to handlers.
"""

from __future__ import annotations

import contextlib
import itertools
import json
import socket
import threading
import time
from collections.abc import Callable
from pathlib import Path

from . import capture
from .client import ConsoleInUse, HumanHasControl, PadError
from .protocol import PadState, Touch

API_VERSION = 1


class AppError(PadError):
    def __init__(self, message: str, code: str | None = None):
        super().__init__(message)
        self.code = code


class AppNotRunning(AppError):
    pass


def state_to_json(state: PadState) -> dict:
    out = {"buttons": state.buttons, "lx": state.lx, "ly": state.ly, "rx": state.rx, "ry": state.ry,
           "l2": state.l2, "r2": state.r2}
    if any(t.active for t in state.touch):
        out["touch"] = [{"active": t.active, "id": t.id, "x": t.x, "y": t.y} for t in state.touch]
    return out


def state_from_json(data: dict) -> PadState:
    touch = tuple(Touch(bool(t.get("active")), t.get("id", 0), t.get("x", 0), t.get("y", 0))
                  for t in data.get("touch", [])) or (Touch(), Touch())
    return PadState(buttons=data.get("buttons", 0), lx=data.get("lx", 0x80), ly=data.get("ly", 0x80),
                    rx=data.get("rx", 0x80), ry=data.get("ry", 0x80), l2=data.get("l2", 0), r2=data.get("r2", 0),
                    touch=(touch + (Touch(), Touch()))[:2])


class AppClient:
    """One connection to the app. Thread-safe; closing it releases this connection's input."""

    def __init__(self, path: Path | None = None, timeout: float = 3.0, client: str | None = None):
        self.path = Path(path or capture.state_dir() / "capture.sock")
        self.timeout = timeout
        self.client = client
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.connect(str(self.path))
        except OSError as exc:
            self.sock.close()
            raise AppNotRunning(f"PS5 app not running ({self.path}: {exc})") from exc
        self._ids = itertools.count(1)
        self._cond = threading.Condition()
        self._replies: dict[int, list[dict]] = {}
        self._handlers: dict[str, list[Callable[[dict], None]]] = {}
        self._send_lock = threading.Lock()
        self.closed = False
        threading.Thread(target=self._read_loop, daemon=True, name="app-reader").start()

    def _read_loop(self) -> None:
        buffer = b""
        try:
            while True:
                data = self.sock.recv(65536)
                if not data:
                    break
                buffer += data
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    if "event" in message:
                        for handler in list(self._handlers.get(message["event"], [])):
                            with contextlib.suppress(Exception):
                                handler(message)
                    elif "id" in message:
                        with self._cond:
                            self._replies.setdefault(message["id"], []).append(message)
                            self._cond.notify_all()
        except OSError:
            pass
        finally:
            with self._cond:
                self.closed = True
                self._cond.notify_all()

    def request(self, cmd: str, timeout: float | None = None, replies: int = 1, **fields) -> list[dict]:
        """Send one command; returns its reply lines (watch_change answers twice). Never raises on ok=false."""
        if self.closed:
            raise AppNotRunning("connection to the PS5 app closed")
        id_ = next(self._ids)
        if self.client and "client" not in fields:
            fields["client"] = self.client
        line = (json.dumps({"cmd": cmd, "id": id_, **fields}) + "\n").encode()
        with self._send_lock:
            try:
                self.sock.sendall(line)
            except OSError as exc:
                raise AppNotRunning(f"PS5 app connection failed: {exc}") from exc
        deadline = time.monotonic() + (timeout or self.timeout)
        with self._cond:
            while len(self._replies.get(id_, [])) < replies:
                if self.closed:
                    raise AppNotRunning("connection to the PS5 app closed")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AppError(f"timed out waiting for the PS5 app ({cmd})", "timeout")
                self._cond.wait(remaining)
            return self._replies.pop(id_)

    def call(self, cmd: str, timeout: float | None = None, **fields) -> dict:
        """One-reply command; raises HumanHasControl / ConsoleInUse / AppError when the app says ok=false."""
        reply = self.request(cmd, timeout, **fields)[0]
        if not reply.get("ok"):
            if reply.get("code") == "human_has_control":
                raise HumanHasControl(reply.get("error", "human has control"))
            if reply.get("code") == "leased":
                raise ConsoleInUse(reply.get("error", "the PS5 is in use"))
            raise AppError(reply.get("error", "failed"), reply.get("code"))
        return reply

    def on(self, event: str, handler: Callable[[dict], None]) -> None:
        self._handlers.setdefault(event, []).append(handler)

    def subscribe(self, *events: str) -> dict:
        return self.call("subscribe", events=list(events))

    # -- input --------------------------------------------------------------
    def set(self, state: PadState, wait: float = 0.0) -> None:
        self.call("set", state=state_to_json(state), wait=wait, timeout=wait + self.timeout)

    def press(self, state: PadState, hold_ms: int, wait: float = 2.0) -> None:
        self.call("press", state=state_to_json(state), hold_ms=hold_ms, wait=wait,
                  timeout=wait + hold_ms / 1000 + self.timeout)

    def release(self) -> None:
        self.call("release")

    def release_all(self) -> None:
        self.call("release_all")

    def key(self, key: str, down: bool) -> None:
        self.call("key", key=key, down=down)

    def command(self, op: str, arg: str = "", timeout: float = 12.0) -> int:
        return self.call("command", op=op, arg=arg, timeout=timeout)["status"]

    def status(self) -> dict:
        return self.call("status")

    # -- sharing (one connection claims the console, the others queue) ---------
    def claim(self, reason: str = "", idle_s: float | None = None) -> dict:
        """Claim the console or keep this connection's place in the queue; `granted` says which."""
        fields = {"reason": reason} | ({"idle_s": float(idle_s)} if idle_s is not None else {})
        return self.call("claim", **fields)

    def unclaim(self) -> dict:
        return self.call("unclaim")

    def lease(self) -> dict:
        return self.call("lease")

    def ping(self) -> dict:
        return self.call("ping", timeout=5.0)["pong"]

    def close(self) -> None:
        self.closed = True
        with contextlib.suppress(OSError):
            self.sock.shutdown(socket.SHUT_RDWR)
        self.sock.close()


def connect(root: Path | None = None, client: str | None = None, start: bool = True, visible: bool = False,
            timeout: float = 15.0) -> AppClient:
    """Connect to the running app, launching it (headless unless `visible`) when `start` is set."""
    app = capture.NativeApp(root)
    if start:
        app.start(visible=visible, timeout=timeout)
    elif visible:
        app.show()
    return AppClient(app.socket, client=client)
