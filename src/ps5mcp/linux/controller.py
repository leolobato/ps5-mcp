"""ACK-checked padd transport and cached, read-only Linux controller telemetry."""
from __future__ import annotations

import contextlib
import math
import os
import struct
import threading
from dataclasses import asdict, dataclass

from .. import protocol as p
from ..client import PadController, PadError, PadLink
from ..hub import AppClient, AppError, state_to_json


@dataclass(frozen=True)
class ConnectionConfig:
    host: str | None
    port: int = p.PORT
    enabled: bool = False
    timeout: float = 0.75

    def validate(self):
        if type(self.port) is not int or not 1 <= self.port <= 65535:
            raise ValueError("PS5MCP_PAD_PORT must be 1..65535")
        if not math.isfinite(self.timeout) or not .1 <= self.timeout <= 10:
            raise ValueError("Controller timeout must be 0.1..10 seconds")
        if self.enabled and (not self.host or not self.host.strip() or any(c.isspace() for c in self.host)):
            raise ValueError("Console opt-in requires an explicit PS5_HOST or --host; no address is discovered")


class LinuxAppClient(AppClient):
    def __init__(self, *args, **kwargs):
        self.console_allowed = os.environ.get("PS5MCP_ALLOW_CONSOLE") == "1"
        super().__init__(*args, **kwargs)

    def request(self, *args, **kwargs):
        command = args[0] if args else kwargs.get("cmd")
        if command in ("set", "press", "command", "begin_sequence") and not self.console_allowed:
            raise PadError("Console access disabled for this client (offline mode)")
        try:
            return super().request(*args, **kwargs)
        except (AppError, OSError):
            # A local timeout is not cancellation of the hub's work. EOF cancels it.
            self.close()
            raise

    def begin_sequence(self):
        return self.call("begin_sequence")["input_epoch"]

    def abort_input(self):
        self.close()  # EOF cancels the hold, including an in-flight ACK wait.

    def set_sequence(self, state, wait, epoch):
        self.call("set", state=state_to_json(state), wait=wait, operation_epoch=epoch,
                  timeout=wait + self.timeout)


class LinuxController(PadController):
    def __init__(self, config: ConnectionConfig, reset):
        config.validate()
        if not config.enabled:
            raise ValueError("Console connections require explicit opt-in")
        self.timeout = config.timeout
        self.command_timeout = 10.0
        self.operations = threading.Lock()
        self.telemetry_lock = threading.Lock()
        self.controllers = None
        self.login_users = None
        self.notice = None
        self.pong = None
        self._telemetry_stop = threading.Event()
        def clear_connection():
            with self.telemetry_lock:
                self.controllers = self.login_users = self.pong = None
            reset()
        super().__init__(config.host, config.port, connect=lambda host, port: PadLink(host, port, self.timeout),
                         ack_timeout=self.timeout, on_ready=clear_connection, on_disconnect=clear_connection)
        self._telemetry_thread = threading.Thread(target=self._telemetry, daemon=True, name="padd-telemetry")
        self._telemetry_thread.start()

    def abort(self):
        self.release_all()
        with contextlib.suppress(PadError):
            # Closing the TCP link also makes padd neutralise its virtual controller.
            self.link().close()

    def _telemetry(self):
        while not self._telemetry_stop.wait(.5):
            with self.operations:
                try:
                    self.refresh()
                except (PadError, OSError, struct.error, IndexError):
                    with self.telemetry_lock:
                        self.controllers = self.login_users = self.pong = None
                    self.abort()

    def refresh(self):
        link = self.link()
        pong = link.ping(timeout=self.timeout)
        users = link.get_users(timeout=self.timeout)
        pads = link.get_pads(timeout=self.timeout)
        names = {u.user_id: u.name for u in users.users} if users else {}
        with self.telemetry_lock:
            self.pong = asdict(pong)
            self.login_users = as_users(users)
            if pads:
                entries = [{"controller": i + 1, "handle": handle, "user_id": uid, "user_name": names.get(uid)}
                           for i, (handle, uid) in enumerate(zip(pads.handles, pads.user_ids)) if handle >= 0]
                used = {entry["user_id"] for entry in entries}
                self.controllers = {"active": pads.active, "list": entries, "supported": True,
                                    "second": pads.handles[1] >= 0, "max": len(pads.handles),
                                    "available": [{"user_id": uid, "name": name} for uid, name in names.items()
                                                  if uid not in used]}
            else:
                self.controllers = {"active": 1, "supported": False, "list": [], "second": False,
                                    "max": 1, "available": []}

    def cached(self):
        with self.telemetry_lock:
            if not self.status().connected:
                return None, None, None
            return self.controllers, self.login_users, self.pong

    def command(self, op, arg, cancelled=None):
        operations = {"pad": p.Command.PAD, "select_pad": p.Command.SELECT_PAD,
                      "home": p.Command.HOME, "close": p.Command.CLOSE, "launch": p.Command.LAUNCH}
        if op not in operations:
            raise ValueError(f"Unsupported Linux console command: {op}")
        def check_cancelled():
            if cancelled is not None and cancelled.is_set():
                raise ValueError("Controller command interrupted; remaining operations are not replayed")
        with self.operations:
            check_cancelled()
            link = self.link()
            before = link.get_pads(timeout=self.timeout) if op == "pad" else None
            check_cancelled()
            result = link.command(operations[op], arg, timeout=self.command_timeout)
            check_cancelled()
            if result == 0 and op == "pad" and arg.startswith("connect"):
                after = link.get_pads(timeout=self.timeout)
                if before and after:
                    added = [i + 1 for i, (a, b) in enumerate(zip(before.handles, after.handles)) if a < 0 <= b]
                    if added:
                        check_cancelled()
                        result = link.command(p.Command.SELECT_PAD, str(added[0]), timeout=self.timeout)
                self.notice = "Linux leaves controller assignment prompts to the user; no automatic buttons are pressed"
            self.refresh()
            return result

    def close(self, neutral=True):
        self._telemetry_stop.set()
        super().close(neutral=neutral)
        self._telemetry_thread.join(timeout=3)
        self._thread.join(timeout=3)


def as_users(users):
    if users is None:
        return None
    return {"status": users.status, "foreground": users.foreground,
            "users": [{"user_id": u.user_id, "name": u.name} for u in users.users]}


def config_from_environment(host=None, port=None):
    config = ConnectionConfig(host if host is not None else os.environ.get("PS5_HOST"),
                              int(port if port is not None else os.environ.get("PS5MCP_PAD_PORT", p.PORT)),
                              os.environ.get("PS5MCP_ALLOW_CONSOLE") == "1")
    config.validate()
    return config
