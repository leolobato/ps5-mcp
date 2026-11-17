"""Headless Unix socket hub. Console networking is explicitly opt-in."""
from __future__ import annotations

import argparse
import base64
import contextlib
import fcntl
import io
import json
import math
import os
import queue
import re
import select
import signal
import socket
import socketserver
import threading
import time
from dataclasses import asdict
from importlib.metadata import version
from pathlib import Path

from PIL import Image, ImageDraw

from ..capture import CaptureError
from ..client import HumanHasControl, PadError
from ..hub import state_from_json, state_to_json
from ..protocol import PadState
from .controller import LinuxController, config_from_environment
from .video import PBS_SOURCE, FFmpegCapture, Frame, PBSCapture, VideoConfig, pbs_port_from_environment
from .viewer import metadata, start_viewer


class Refused(ValueError):
    def __init__(self, message, code="bad_request"):
        super().__init__(message)
        self.code = code


class Hub:
    def __init__(self, root: Path, video="synthetic", host=None, port=None, controller=None, video_config=None, viewer_port=0):
        self.root, self.video = root, video
        self.latest = root / "latest.jpg"
        self.lock = threading.RLock()
        self.sessions = {}
        self.queue = []
        self.owner = None
        self.frame_time = None
        self.frames = 0
        self.capture_error = None
        self.controller = controller
        self.host, self.port = host, port
        self.server = None
        self.stopping = threading.Event()
        self.worker = None
        self.video_config = video_config
        self.video_capture = None
        self.viewer = None
        self.viewer_thread = None
        self.viewer_port = viewer_port
        self.frame_unix = None
        self.input_owner = None
        self.neutral_revision = 0
        self.config = config_from_environment(host, port)
        self.host, self.port = self.config.host, self.config.port
        if controller:
            self.controller.on_connected = self.reset_input

    def clear_session(self, key):
        session = self.sessions.get(key)
        if session:
            session["cancel"].set()
            session["epoch"] += 1
            session["state"] = PadState()
            session["input_deadline"] = None
        if self.input_owner == key:
            self.input_owner = None

    def reset_input(self):
        with self.lock:
            for key in self.sessions:
                self.clear_session(key)
            self.merge()

    def failed_transport(self):
        self.reset_input()
        if isinstance(self.controller, LinuxController):
            self.controller.abort()

    @property
    def released_file(self):
        """Present while padd is left to another hub (the macOS app): kept across restarts of this hub."""
        return self.root / "padd-released"

    def start_controller(self):
        if self.controller is None and self.config.enabled:
            self.controller = LinuxController(self.config, self.reset_input, released=self.released_file.exists())

    def hand_over(self, release):
        """padd_release / padd_take: padd accepts one client, so a hub that hands it over must stay off it."""
        if not self.controller:
            raise Refused("Console access disabled (offline mode)", "offline")
        if release:
            self.released_file.touch()
            self.reset_input()
            self.controller.release()
        else:
            self.released_file.unlink(missing_ok=True)
            self.controller.take()
        return {"released": release}

    def start_capture(self):
        if self.video.startswith(("/dev/", "v4l2:", "lavfi:")):
            config = self.video_config or VideoConfig.environment(self.video)
            self.video_capture = FFmpegCapture(config, self.latest)
            self.video_capture.start()
        elif self.video == PBS_SOURCE:
            # PBS is console networking: it follows the same explicit opt-in as padd.
            if not self.config.enabled:
                self.capture_error = ("PBS video needs PS5MCP_ALLOW_CONSOLE=1 and PS5_HOST; "
                                      "restart the hub with both set")
                return
            config = self.video_config or VideoConfig.environment(PBS_SOURCE)
            self.video_capture = PBSCapture(config, self.latest, self.host, pbs_port_from_environment())
            self.video_capture.start()
        else:
            self.capture()

    def read_frame(self):
        if self.video_capture:
            return self.video_capture.get()
        with self.lock:
            if self.capture_error:
                raise CaptureError(self.capture_error)
            if self.frame_time is None or time.monotonic() - self.frame_time > 2:
                raise CaptureError("No fresh capture frame")
            return Frame(self.latest.read_bytes(), self.frames, self.frame_time, self.frame_unix)

    def viewer_status(self):
        with self.lock:
            return self.status()

    def capture(self):
        if self.video_capture:
            return
        try:
            if self.video == "synthetic":
                image = Image.new("RGB", (1280, 720), "#183345")
                ImageDraw.Draw(image).text((32, 32), "PS5 MCP - synthetic offline capture", fill="white")
            elif self.video.startswith("file:"):
                with Image.open(self.video[5:]) as source:
                    image = source.convert("RGB")
            else:
                raise ValueError("Unsupported source: choose synthetic, file:PATH, lavfi:FILTER, pbs "
                                 "or an explicit /dev/... device")
            temporary = self.root / "latest.tmp"
            image.save(temporary, format="JPEG")
            temporary.replace(self.latest)
            self.frame_time = time.monotonic()
            self.frame_unix = time.time()
            self.frames += 1
            self.capture_error = None
        except (OSError, ValueError) as exc:
            self.capture_error = str(exc)

    def watch_change(self, request, ended=None):
        """Yields two replies, as the macOS app does: armed, then the first frame that differs from the reference
        (the first frame after arming) by `threshold` mean luma steps on a 32x18 grid, or a timeout.
        Stops early, without a reply, when `ended` is set (the client went away)."""
        ended = ended or threading.Event()
        threshold, timeout = request.get("threshold", 6.0), request.get("timeout_s", 2.0)
        for name, value, top in (("threshold", threshold, 255), ("timeout_s", timeout, 60)):
            if type(value) not in (int, float) or not math.isfinite(value) or not 0 < value <= top:
                raise Refused(f"{name} must be in (0, {top}]")
        armed = time.monotonic()
        yield {"armed_at": armed}
        reference, seen = None, None
        while time.monotonic() < armed + timeout and not self.stopping.is_set():
            if ended.is_set():
                return
            try:
                frame = self.read_frame()
            except CaptureError:
                frame = None
            if frame is None or frame.sequence == seen or frame.monotonic < armed:
                self.stopping.wait(0.01)
                continue
            seen = frame.sequence
            grid = luma_grid(frame.jpeg)
            if reference is None:
                reference = grid
                continue
            diff = sum(abs(a - b) for a, b in zip(grid, reference)) / len(grid)
            if diff >= threshold:
                yield {"changed_at": frame.monotonic, "diff": diff}
                return
        yield {"ok": False, "error": "timeout"}

    def maintain(self):
        while not self.stopping.wait(0.1):
            with self.lock:
                self.expire()
                self.capture()

    def expire(self):
        if self.owner is not None:
            session = self.sessions[self.owner]
            if time.monotonic() - session["t"] >= session["idle_s"]:
                self.clear_session(self.owner)
                self.owner = None
                self.merge()
        if self.input_owner is not None:
            active = self.sessions.get(self.input_owner)
            if active and active["input_deadline"] and time.monotonic() >= active["input_deadline"]:
                self.clear_session(self.input_owner)
                self.merge()
        if self.owner is None and self.queue:
            self.owner = self.queue.pop(0)
            self.sessions[self.owner]["t"] = time.monotonic()
            self.sessions[self.owner]["claimed_at"] = time.monotonic()

    def human(self, key, session, state):
        """A person's keys (the macOS app's window): the merged state they hold, or None when they let go. Like the
        app's own keyboard, it needs no claim, cancels agent holds, and keeps agents out until released."""
        if not self.controller:
            raise Refused("Console access disabled (offline mode)", "offline")
        layer = f"human:{key}"
        if state is None:
            session["human"] = False
            self.controller.key(layer, None)
            return {"human": False}
        state = checked_state(state)
        if not self.controller.status().human_active:
            for other in self.sessions:  # a person taking over cancels every agent hold
                self.clear_session(other)
            self.merge()
        session["human"] = True
        self.controller.key(layer, state)
        return {"human": True}

    def merge(self):
        state = PadState()
        for session in self.sessions.values():
            if not session["state"].is_neutral():
                state = session["state"]
        if self.controller:
            with contextlib.suppress(HumanHasControl):  # a person's keys win; agents were reset when they started
                self.controller.set_agent(state)
            if state.is_neutral():
                self.neutral_revision = self.controller.revision
        event = {"event": "state", "t": time.monotonic(), "state": state_to_json(state)}
        for session in self.sessions.values():
            if "state" in session["events"]:
                session["send"](event)
        return state

    def disconnect(self, key):
        with self.lock:
            if self.sessions.get(key, {}).get("human") and self.controller:
                self.controller.key(f"human:{key}", None)  # the window went away: its keys let go
            self.clear_session(key)
            self.sessions.pop(key, None)
            if key in self.queue:
                self.queue.remove(key)
            if self.owner == key:
                self.owner = None
            self.expire()
            self.merge()

    def lease(self, key):
        def entry(k):
            s = self.sessions[k]
            return {"client": s["client"], "reason": s["reason"],
                    "held_s": time.monotonic() - s.get("claimed_at", s["t"]),
                    "expires_in_s": max(0, s["idle_s"] - (time.monotonic() - s["t"]))}
        return {"granted": self.owner == key, "position": self.queue.index(key) + 1 if key in self.queue else 0,
                "owner": entry(self.owner) if self.owner else None, "queue": [entry(k) for k in self.queue]}

    def status(self):
        link = asdict(self.controller.status()) if self.controller else {
            "connected": False, "host": self.host, "port": self.port,
            "error": "Console access disabled; set PS5MCP_ALLOW_CONSOLE=1 only after authorization",
            "reconnects": 0, "human_active": False}
        link.update(human_has_control=link.pop("human_active", False),
                    agent_layers=sum(not s["state"].is_neutral() for s in self.sessions.values()))
        link["enabled"] = self.config.enabled
        link["states_sent"] = self.controller.states_sent if self.controller else 0
        if link.get("hello"):
            from ..protocol import version_string
            link["version"] = version_string(link["hello"]["payload_version"])
        controllers, users, pong = self.controller.cached() if isinstance(self.controller, LinuxController) else (None, None, None)
        result = {"pid": os.getpid(), "backend": "LinuxHub", "version": version("ps5-mcp"), "build": "linux",
                "frames": self.frames, "frame_age": time.monotonic() - self.frame_time if self.frame_time else -1,
                "source": "unavailable" if self.capture_error else self.video, "configured_source": self.video,
                "capture_error": self.capture_error,
                "visible": False, "clients": len(self.sessions), "pad": link, "controllers": controllers, "pong": pong,
                "login_users": users, "notice": self.capture_error or getattr(self.controller, "notice", None), "padd": {}, "now": time.monotonic(),
                "frame_sequence": self.frames, "frame_timestamp": self.frame_time,
                "frame_timestamp_unix": self.frame_unix,
                "viewer_url": f"http://127.0.0.1:{self.viewer.server_port}/" if self.viewer else None}
        if self.video_capture:
            result.update(self.video_capture.info())
            result["frames"] = result["frame_sequence"]
            result["source"] = "unavailable" if result["capture_error"] else self.video
            result["notice"] = result["capture_error"] or getattr(self.controller, "notice", None)
            config = self.video_capture.config
            result["video_config"] = {"source": config.source, "input_format": config.input_format,
                                      "size": config.size, "fps": config.fps}
            if "pbs" in result:
                result["video_config"]["pbs_port"] = result["pbs"]["port"]
        return result

    def dispatch(self, key, request, expected_epoch=None):
        cmd = request.get("cmd")
        with self.lock:
            self.expire()
            session = self.sessions[key]
            session["client"] = str(request.get("client", session["client"]))
            session["t"] = time.monotonic()
            if cmd == "status":
                return self.status()
            if cmd == "subscribe":
                events = request.get("events", [])
                if not isinstance(events, list) or any(e != "state" for e in events):
                    raise Refused("Only state subscriptions are supported", "unsupported")
                session["events"] = events
                return {}
            if cmd in ("claim", "unclaim", "lease"):
                released = False
                if cmd == "claim":
                    idle = float(request.get("idle_s", 600))
                    if not math.isfinite(idle) or not 10 <= idle <= 3600:
                        raise Refused("idle_s must be 10..3600")
                    session.update(reason=str(request.get("reason", "")), idle_s=idle)
                    if self.owner != key and key not in self.queue:
                        self.queue.append(key)
                    # A claim cancels other agents' existing held input.
                    if self.owner is None:
                        self.reset_input()
                if cmd == "unclaim":
                    released = self.owner == key or key in self.queue
                    if self.owner == key:
                        self.owner = None
                    if key in self.queue:
                        self.queue.remove(key)
                    self.clear_session(key)
                    self.merge()
                self.expire()
                return {**self.lease(key), "released": released}
            if cmd == "show":
                return {"viewer_url": self.status()["viewer_url"]}
            if cmd == "snapshot":
                self.capture()
                try:
                    frame = self.read_frame()
                except CaptureError as exc:
                    raise Refused(str(exc), "capture") from exc
                result = {"path": str(self.latest), **metadata(frame)}
                if request.get("include_data"):
                    result["jpeg_base64"] = base64.b64encode(frame.jpeg).decode("ascii")
                return result
            if cmd == "state":
                state = next((s["state"] for s in self.sessions.values() if not s["state"].is_neutral()), PadState())
                return {"state": state_to_json(state)}
            if cmd == "release":
                self.clear_session(key)
                self.merge()
                return {}
            if cmd == "human":
                return self.human(key, session, request.get("state"))
            agent_input = cmd in ("press", "command", "begin_sequence") or (
                cmd == "set" and not checked_state(request.get("state", {})).is_neutral())
            if agent_input and self.controller and self.controller.status().human_active:
                raise Refused("A person is using the keyboard in the PS5 MCP window; try again when they let go",
                              "human_has_control")
            if cmd != "ping" and self.owner is not None and self.owner != key:
                raise Refused("Console claimed by another agent", "leased")
            if cmd == "release_all":
                self.reset_input()
                return {}
            if cmd == "quit":
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return {}
            if cmd not in ("set", "press", "ping", "command", "begin_sequence", "controller_verify"):
                raise Refused(f"Linux backend does not support {cmd!r}", "unsupported")
            if not self.controller:
                raise Refused("Console access disabled (offline mode)", "offline")
            if cmd != "ping" and self.input_owner not in (None, key):
                raise Refused("Another session has active input; claim the console before acting", "leased")
            if cmd == "controller_verify" and self.owner != key:
                raise Refused("Claim console before verifying controller", "leased")
            if request.get("require_claim") and self.owner != key:
                raise Refused("Claim console before guarded input", "leased")
            epoch = session["epoch"]
            if expected_epoch is not None and expected_epoch != epoch:
                raise Refused("Input was interrupted; queued actions are not replayed", "interrupted")
            wait = float(request.get("wait", 0))
            if not math.isfinite(wait) or not 0 <= wait <= 30:
                raise Refused("wait must be 0..30 seconds")
        # Network waits never hold the hub lock, so disconnect/release/status can proceed.
        try:
            link = self.controller.link(wait=wait)
            if cmd == "ping":
                operations = getattr(self.controller, "operations", contextlib.nullcontext())
                with operations:
                    return {"pong": asdict(link.ping())}
            if self.controller.ack_timeout is not None:
                with self.lock:
                    barrier = self.neutral_revision
                self.controller.wait_applied(barrier, self.controller.ack_timeout + .2)
            with self.lock:
                self.expire()
                if self.controller.ack_timeout is not None and self.controller.acked_revision < self.neutral_revision:
                    raise Refused("Input release is pending; retry after it is acknowledged", "interrupted")
                if key not in self.sessions or epoch != session["epoch"] or self.owner not in (None, key):
                    raise Refused("Session input interrupted or ownership lost", "interrupted")
                if request.get("require_claim") and self.owner != key:
                    raise Refused("Console claim lost before guarded input", "leased")
                if self.input_owner not in (None, key):
                    raise Refused("Another session has active input", "leased")
                operation_epoch = request.get("operation_epoch")
                if operation_epoch is not None and operation_epoch != epoch:
                    raise Refused("Sequence interrupted; reconnects never resume old steps", "interrupted")
                if cmd == "controller_verify":
                    if not isinstance(self.controller, LinuxController):
                        raise Refused("Controller verification requires Linux padd", "unsupported")
                    # Recheck ownership/epoch after bounded network read; no input is sent.
                    verify_epoch = epoch
                if cmd == "begin_sequence":
                    return {"input_epoch": epoch}
                if cmd == "controller_verify":
                    pass
                elif cmd == "command":
                    op, arg = request.get("op"), request.get("arg", "")
                    validate_command(op, arg)
                    if not isinstance(self.controller, LinuxController):
                        raise Refused("Controller commands need the Linux padd manager", "unsupported")
                    self.clear_session(key)
                    cancelled = session["cancel"] = threading.Event()
                    self.input_owner = key
                    session["input_deadline"] = time.monotonic() + 11
                    self.merge()
                    revision = self.controller.revision
                else:
                    state = checked_state(request.get("state", {}))
                    duration = request.get("hold_ms", 80)
                    if cmd == "press" and (type(duration) is not int or not 1 <= duration <= 10000):
                        raise Refused("hold_ms must be 1..10000")
                    session["cancel"].set()
                    cancelled = session["cancel"] = threading.Event()
                    session["state"] = state
                    self.input_owner = None if state.is_neutral() else key
                    session["input_deadline"] = time.monotonic() + (duration / 1000 + 1 if cmd == "press" else 11)
                    self.merge()
                    revision = self.controller.revision
            if cmd == "controller_verify":
                with self.controller.operations:
                    state = link.get_state(timeout=1)
                    pong = link.ping(timeout=1)
                with self.lock:
                    self.expire()
                    if self.owner != key or key not in self.sessions or session["epoch"] != verify_epoch:
                        raise Refused("Ownership changed during verification", "interrupted")
                return {"connected": True, "hello": asdict(link.hello), "pong": asdict(pong),
                        "state": asdict(state), "neutral": state.is_neutral() and not any(t.active for t in state.touch)}
            if self.controller.ack_timeout is not None:
                self.controller.wait_applied(revision, self.controller.ack_timeout + .2)
            if cmd == "command":
                try:
                    return {"status": self.controller.command(op, arg, cancelled=cancelled)}
                finally:
                    with self.lock:
                        if key in self.sessions and session["cancel"] is cancelled:
                            self.clear_session(key)
                            self.merge()
            if cancelled.is_set():
                raise Refused("Input interrupted", "interrupted")
            if cmd == "press":
                try:
                    if cancelled.wait(duration / 1000):
                        raise Refused("Button hold interrupted", "interrupted")
                finally:
                    with self.lock:
                        if key in self.sessions and session["cancel"] is cancelled:
                            self.clear_session(key)
                            self.merge()
                            revision = self.controller.revision
                    if self.controller.ack_timeout is not None:
                        self.controller.wait_applied(revision, self.controller.ack_timeout + .2)
                self.stopping.wait(.06)
            return {}
        except (PadError, OSError):
            self.failed_transport()
            raise


def validate_command(op, arg):
    patterns = {"pad": r"(?:connect(?: [1-9][0-9]{0,9})?|disconnect(?: [2-4])?)",
                "select_pad": r"[1-4]", "launch": r"[A-Z]{4}[0-9]{5}", "uninstall": r"[A-Z]{4}[0-9]{5}",
                "home": r"(?:system|shellcore|suspend)", "close": r""}
    if op not in patterns:
        raise Refused(f"Unsupported Linux console command: {op}", "unsupported")
    if not isinstance(arg, str) or re.fullmatch(patterns[op], arg) is None:
        raise Refused(f"Invalid argument for {op}")


def luma_grid(jpeg: bytes) -> list[int]:
    """32x18 luma cells. JPEG draft mode decodes at reduced scale, so a 1080p frame stays cheap at 60 fps."""
    with Image.open(io.BytesIO(jpeg)) as image:
        image.draft("L", (64, 36))
        return list(image.convert("L").resize((32, 18), Image.Resampling.BOX).getdata())


def checked_state(data):
    if not isinstance(data, dict):
        raise Refused("state must be an object")
    for field, value in data.items():
        if field == "touch":
            if not isinstance(value, list) or len(value) > 2:
                raise Refused("touch must contain at most two contacts")
            for contact in value:
                if not isinstance(contact, dict) or set(contact) - {"active", "id", "x", "y"}:
                    raise Refused("Invalid touch contact")
                for name, number in contact.items():
                    if name == "active":
                        if type(number) is not bool:
                            raise Refused("Touch active must be boolean")
                    elif type(number) is not int or not 0 <= number <= (127 if name == "id" else 65535):
                        raise Refused(f"Invalid touch {name}")
            continue
        if field not in ("buttons", "lx", "ly", "rx", "ry", "l2", "r2"):
            raise Refused(f"Unsupported state field: {field}")
        if type(value) is not int or not 0 <= value <= (0xFFFFFFFF if field == "buttons" else 255):
            raise Refused(f"Invalid {field}")
    return state_from_json(data)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        hub = self.server.hub
        key = object()
        outgoing = queue.Queue(maxsize=64)
        writer_stopped = threading.Event()

        def send(message):
            # Called under the hub lock: never wait for a slow subscriber here.
            try:
                outgoing.put_nowait((json.dumps(message) + "\n").encode())
            except queue.Full:
                writer_stopped.set()
                with contextlib.suppress(OSError):
                    self.connection.shutdown(socket.SHUT_RDWR)

        def write():
            while not writer_stopped.is_set():
                try:
                    data = memoryview(outgoing.get(timeout=.1))
                except queue.Empty:
                    continue
                deadline = time.monotonic() + 2
                try:
                    while data and not writer_stopped.is_set():
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise TimeoutError("Local client is not reading replies")
                        if not select.select([], [self.connection], [], min(.1, remaining))[1]:
                            continue
                        try:
                            count = self.connection.send(data, socket.MSG_DONTWAIT)
                        except BlockingIOError:
                            continue
                        if count == 0:
                            raise ConnectionError("Local client disconnected")
                        data = data[count:]
                except OSError:
                    writer_stopped.set()
                    with contextlib.suppress(OSError):
                        self.connection.shutdown(socket.SHUT_RDWR)

        writer = threading.Thread(target=write, daemon=True, name="hub-writer")
        writer.start()
        with hub.lock:
            hub.sessions[key] = {"state": PadState(), "events": [], "send": send, "client": "local",
                                 "reason": "", "idle_s": 600, "t": time.monotonic(), "socket": self.connection,
                                 "epoch": 0, "cancel": threading.Event(), "input_deadline": None}
        # One bounded worker per session. The reader remains available for EOF and emergency release.
        pending = queue.Queue(maxsize=32)
        ended = threading.Event()

        def execute(request, epoch=None):
            try:
                if request.get("cmd") == "watch_change":  # read-only; answers twice
                    for result in hub.watch_change(request, ended):
                        send({"id": request.get("id"), "ok": True, **result})
                    return
                if request.get("cmd") in ("padd_release", "padd_take"):  # outside the hub lock: the link closes first
                    result = hub.hand_over(request["cmd"] == "padd_release")
                    send({"id": request.get("id"), "ok": True, **result})
                    return
                result = hub.dispatch(key, request, expected_epoch=epoch)
                send({"id": request.get("id"), "ok": True, **result})
            except (ValueError, TypeError, KeyError, PadError, OSError) as exc:
                send({"id": request.get("id"), "ok": False, "error": str(exc),
                      "code": getattr(exc, "code", "bad_request")})

        def work():
            while not ended.is_set():
                try:
                    request, epoch = pending.get(timeout=.1)
                except queue.Empty:
                    continue
                if not ended.is_set():
                    execute(request, epoch)
        worker = threading.Thread(target=work, daemon=True, name="hub-session")
        worker.start()
        immediate = {"release", "release_all", "unclaim", "status", "state", "lease", "show", "snapshot", "quit",
                     "padd_release", "padd_take"}
        try:
            while line := self.rfile.readline(65537):
                if len(line) > 65536:
                    break
                request = None
                try:
                    request = json.loads(line)
                    if not isinstance(request, dict):
                        raise TypeError("request must be an object")
                    if request.get("cmd") in immediate:
                        execute(request)
                    else:
                        with hub.lock:
                            epoch = hub.sessions[key]["epoch"]
                        pending.put_nowait((request, epoch))
                except (ValueError, TypeError, queue.Full) as exc:
                    send({"id": request.get("id") if isinstance(request, dict) else None,
                          "ok": False, "error": str(exc), "code": "bad_request"})
        except OSError:
            pass  # Peer reset/timeout is ordinary session cleanup, not a server failure.
        finally:
            ended.set()
            writer_stopped.set()
            hub.disconnect(key)
            writer.join(timeout=3)


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def serve(hub: Hub, ready=None):
    hub.root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (hub.root / "hub.lock").open("a") as lockfile:
        fcntl.flock(lockfile, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = hub.root / "capture.sock"
        path.unlink(missing_ok=True)
        with Server(str(path), Handler) as server:
            os.chmod(path, 0o600)
            hub.server = server
            server.hub = hub
            try:
                hub.start_controller()
                hub.start_capture()
                hub.viewer, hub.viewer_thread = start_viewer(hub.read_frame, hub.viewer_status,
                                                           hub.stopping, hub.viewer_port)
                hub.worker = threading.Thread(target=hub.maintain, daemon=True)
                hub.worker.start()
                if ready:
                    ready.set()
                server.serve_forever(poll_interval=0.05)
            finally:
                hub.stopping.set()
                # Input safety precedes potentially slower capture/viewer teardown.
                hub.reset_input()
                for session in list(hub.sessions.values()):
                    with contextlib.suppress(OSError):
                        session["socket"].shutdown(2)
                if hub.controller:
                    hub.controller.close()
                if hub.worker:
                    hub.worker.join()
                if hub.viewer:
                    hub.viewer.shutdown()
                    hub.viewer.server_close()
                    hub.viewer_thread.join()
                if hub.video_capture:
                    hub.video_capture.stop()
                path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--video", default=os.environ.get("PS5MCP_VIDEO", "synthetic"))
    parser.add_argument("--host", default=os.environ.get("PS5_HOST"))
    args = parser.parse_args()
    hub = Hub(args.state_dir, args.video, args.host, int(os.environ.get("PS5MCP_PAD_PORT", "9305")),
              viewer_port=int(os.environ.get("PS5MCP_VIEWER_PORT", "0")))
    def stop(*_):
        if hub.server:
            threading.Thread(target=hub.server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    serve(hub)


if __name__ == "__main__":
    main()
