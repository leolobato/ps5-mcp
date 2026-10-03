"""ps5-mcp MCP server (stdio): see the PS5 through the capture card, drive it through padd.

A thin client of the PS5 app (app/*.swift), which owns the capture card and the only padd connection. Several
servers (and the keyboard in the app window) can drive the console at once; the app merges their input. If the
app is not running, the server launches it: headless, or visible with PS5MCP_VIEW=1.

Environment: PS5_HOST (the console's IP address, required), PS5MCP_VIEW=1, PS5MCP_STATE (the app's state dir).
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import tempfile
import threading
import time
from collections.abc import AsyncIterator
from pathlib import Path

from mcp.server.mcpserver import Image, MCPServer

from . import capture, recording, stream, vision
from . import protocol as p
from .client import HumanHasControl, PadError
from .hub import AppClient, state_from_json
from .protocol import PadState

HOST = os.environ.get("PS5_HOST")
MAX_HOLD_MS = 10_000
HOME_METHOD = os.environ.get("PS5MCP_HOME_METHOD", "suspend")
# The PS5 drops a press that follows a release too closely (seen on 13.60 with 0 ms gaps), so every hold ends
# with this much neutral before the tool returns. The app's `press` adds it; `sequence` adds it here.
RELEASE_GAP_S = 0.06


class Runtime:
    def __init__(self):
        self.capture: capture.NativeApp | None = None
        self.stream = None
        self.recorder: recording.Recorder | None = None
        self._app: AppClient | None = None
        self._lock = threading.Lock()

    def start(self) -> None:
        self.capture = capture.NativeApp()
        with contextlib.suppress(capture.CaptureError, OSError):
            self.app()  # reported by status(); every tool retries
        if port := os.environ.get("PS5MCP_STREAM_PORT"):
            bind = os.environ.get("PS5MCP_STREAM_BIND", "127.0.0.1")
            with contextlib.suppress(OSError):
                self.stream = stream.serve_in_background(bind, int(port), frames=stream.backend_frames(self.capture))

    def app(self) -> AppClient:
        """The connection to the app, launching or reconnecting to it when needed."""
        with self._lock:
            if self._app is None or self._app.closed:
                self.capture.start(visible=os.environ.get("PS5MCP_VIEW") == "1", host=HOST)
                client = AppClient(self.capture.socket, client=f"mcp-{os.getpid()}")
                client.on("state", self._on_state)
                client.subscribe("state")
                self._app = client
            return self._app

    def _on_state(self, event: dict) -> None:
        recorder = self.recorder
        if recorder is not None:
            recorder.note(state_from_json(event["state"]), event["t"])

    def stop(self) -> None:
        """Leaves the app (and the pad) running; only this server's input is released."""
        if self.stream:
            self.stream.shutdown()
        if self._app:
            self._app.close()


runtime = Runtime()


@contextlib.asynccontextmanager
async def lifespan(_server) -> AsyncIterator[None]:
    await asyncio.to_thread(runtime.start)
    try:
        yield
    finally:
        await asyncio.to_thread(runtime.stop)


mcp = MCPServer(
    "ps5",
    instructions=(
        "Controls a PS5 through a virtual DualSense and sees it through an HDMI capture card. "
        "Call snapshot() to look before acting. Buttons: " + ", ".join(p.BUTTONS) + ". "
        "Cross confirms, circle goes back. The PS button cannot be pressed; use home() instead. "
        "If a tool says a human has control, wait and retry."
    ),
    lifespan=lifespan,
)


def _frame(max_width: int | None) -> Image:
    runtime.app()  # the app owns the card; never fall back to opening it here
    with tempfile.TemporaryDirectory() as scratch:
        path = capture.snapshot(Path(scratch) / "frame.jpg", max_width=max_width, daemon=runtime.capture)
        return Image(data=path.read_bytes(), format="jpeg")


async def _snapshot(max_width: int | None = 1280) -> Image:
    return await asyncio.to_thread(_frame, max_width)


async def _app() -> AppClient:
    try:
        return await asyncio.to_thread(runtime.app)
    except (capture.CaptureError, OSError) as exc:
        raise PadError(f"PS5 app not available: {exc}") from exc


def _check_duration(ms: int) -> float:
    if not 0 < ms <= MAX_HOLD_MS:
        raise ValueError(f"duration must be 1..{MAX_HOLD_MS} ms")
    return ms / 1000


async def _apply_for(state: PadState, duration_ms: int) -> None:
    """Hold `state`, release, then the release gap; the app times it (waiting up to 2 s for the padd link)."""
    _check_duration(duration_ms)
    app = await _app()
    await asyncio.to_thread(app.press, state, duration_ms)


async def _result(message: str, snapshot_after_ms: int | None):
    if snapshot_after_ms is None:
        return message
    await asyncio.sleep(max(0, snapshot_after_ms) / 1000)
    return [message, await _snapshot()]


def _errors(fn):
    """Turn expected failures into tool text instead of protocol errors."""
    import functools

    @functools.wraps(fn)
    async def wrapper(*args, **kwargs):
        try:
            return await fn(*args, **kwargs)
        except HumanHasControl as exc:
            return f"human has control: {exc}"
        except (PadError, capture.CaptureError, ValueError) as exc:
            return f"error: {exc}"
    return wrapper


@mcp.tool(structured_output=False)
@_errors
async def snapshot(max_width: int = 1280) -> Image:
    """Current PS5 screen as a JPEG (scaled to max_width; the source is 1920x1080)."""
    return await _snapshot(max_width)


@mcp.tool(structured_output=False)
@_errors
async def press(button: str, hold_ms: int = 80, snapshot_after_ms: int | None = None):
    """Press and release one button (e.g. cross, circle, up, options). Optionally return a frame afterwards."""
    await _apply_for(PadState(buttons=p.button_mask([button])), hold_ms)
    return await _result(f"pressed {button} for {hold_ms} ms", snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def hold(buttons: list[str], duration_ms: int, snapshot_after_ms: int | None = None):
    """Hold several buttons together for duration_ms, then release them."""
    await _apply_for(PadState(buttons=p.button_mask(buttons)), duration_ms)
    return await _result(f"held {', '.join(buttons)} for {duration_ms} ms", snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def stick(side: str, x: float, y: float, duration_ms: int, snapshot_after_ms: int | None = None):
    """Deflect the left or right stick. x, y in -1..1 (left/up negative), then return to centre."""
    if side not in ("left", "right"):
        raise ValueError("side must be left or right")
    bx, by = p.stick_byte(x), p.stick_byte(y)
    state = PadState(lx=bx, ly=by) if side == "left" else PadState(rx=bx, ry=by)
    await _apply_for(state, duration_ms)
    return await _result(f"{side} stick ({x}, {y}) for {duration_ms} ms", snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def trigger(side: str, value: float, duration_ms: int, snapshot_after_ms: int | None = None):
    """Pull L2 or R2 (side: left/right) to value 0..1, then release."""
    if side not in ("left", "right"):
        raise ValueError("side must be left or right")
    level = max(0, min(255, round(value * 255)))
    bit = p.BUTTONS["l2" if side == "left" else "r2"] if value >= 0.5 else 0
    state = PadState(buttons=bit, l2=level) if side == "left" else PadState(buttons=bit, r2=level)
    await _apply_for(state, duration_ms)
    return await _result(f"{side} trigger {value} for {duration_ms} ms", snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def touchpad(x: int = 960, y: int = 540, duration_ms: int = 80, snapshot_after_ms: int | None = None):
    """Click the touchpad. Coordinates are sent but not yet delivered by padd (touch mapping is unknown)."""
    state = PadState(buttons=p.BUTTONS["touchpad"], touch=(p.Touch(True, 0, x, y), p.Touch()))
    await _apply_for(state, duration_ms)
    return await _result(f"touchpad click for {duration_ms} ms (coordinates {x},{y} not delivered)",
                         snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def sequence(steps: list[dict], snapshot_after_ms: int | None = None):
    """Run timed states in order, then release everything.

    Each step: {"buttons": [...], "lx"/"ly"/"rx"/"ry": -1..1, "l2"/"r2": 0..1, "duration_ms": N}.
    A step with no inputs is a pause. Total duration is capped at 60 s.
    """
    total = await _run_steps(steps, max_total_ms=60_000)
    return await _result(f"ran {len(steps)} steps over {total} ms", snapshot_after_ms)


async def _run_steps(steps: list[dict], max_total_ms: int) -> int:
    """Apply timed steps on a monotonic schedule (no drift), then release. Returns the total duration."""
    total = sum(int(step.get("duration_ms", 0)) for step in steps)
    if total > max_total_ms:
        raise ValueError(f"steps last {total} ms; the limit is {max_total_ms} ms")
    states = [(recording.step_to_state(step), _check_duration(int(step.get("duration_ms", 0)))) for step in steps]
    app = await _app()
    deadline = time.monotonic()
    try:
        for index, (state, seconds) in enumerate(states):
            await asyncio.to_thread(app.set, state, 2.0 if index == 0 else 0.0)
            deadline += seconds
            await asyncio.sleep(max(0.0, deadline - time.monotonic()))
    finally:
        with contextlib.suppress(PadError):
            await asyncio.to_thread(app.release)
    await asyncio.sleep(RELEASE_GAP_S)
    return total


@mcp.tool(structured_output=False)
@_errors
async def record_start() -> str:
    """Start recording every input (agent tools and the keyboard in the viewer) as timed steps."""
    app = await _app()
    current = await asyncio.to_thread(app.call, "state")
    recorder = recording.Recorder()
    recorder.note(state_from_json(current["state"]))
    runtime.recorder = recorder
    return "recording; call record_stop(name) to save"


@mcp.tool(structured_output=False)
@_errors
async def record_stop(name: str) -> str:
    """Stop recording and save it under `name` (letters, digits, - and _)."""
    if runtime.recorder is None:
        raise ValueError("not recording; call record_start first")
    vision.check_name(name)
    recorder, runtime.recorder = runtime.recorder, None
    steps = recorder.steps()
    path = recording.save(capture.state_dir(), name, steps, source="mcp")
    return f"saved {len(steps)} steps ({sum(s['duration_ms'] for s in steps)} ms) to {path}"


@mcp.tool(structured_output=False)
@_errors
async def list_recordings() -> list[dict]:
    """Saved recordings with their length."""
    return recording.list_recordings(capture.state_dir())


@mcp.tool(structured_output=False)
@_errors
async def play_recording(name: str, snapshot_after_ms: int | None = 500):
    """Replay a saved recording with its original timing (up to 5 minutes)."""
    steps = recording.load(capture.state_dir(), name)
    total = await _run_steps(steps, max_total_ms=recording.MAX_RECORDING_S * 1000)
    return await _result(f"played {name}: {len(steps)} steps over {total} ms", snapshot_after_ms)


def _current_frame() -> vision.Image.Image:
    runtime.app()
    with tempfile.TemporaryDirectory() as scratch:
        path = capture.snapshot(Path(scratch) / "frame.jpg", daemon=runtime.capture)
        image = vision.Image.open(path)
        image.load()
        return image


@mcp.tool(structured_output=False)
@_errors
async def save_template(name: str, x: int, y: int, width: int, height: int) -> str:
    """Save a region of the current frame (full 1920x1080 coordinates) as a template for wait_for."""
    frame = await asyncio.to_thread(_current_frame)
    path = vision.save_template(capture.state_dir(), name, frame, x, y, width, height)
    return f"saved template {name} ({width}x{height} at {x},{y}) to {path}"


@mcp.tool(structured_output=False)
@_errors
async def list_templates() -> list[str]:
    """Saved template names."""
    return vision.list_templates(capture.state_dir())


@mcp.tool(structured_output=False)
@_errors
async def wait_for(template: str, timeout_ms: int = 5000, min_score: float = 0.85, gone: bool = False):
    """Wait until a saved template appears on screen (or disappears, with gone=true).

    Matching is normalised cross-correlation over the whole frame; score 1.0 is identical. Returns where it was
    found, the score and the frame.
    """
    target, _ = vision.load_template(capture.state_dir(), template)
    started = time.monotonic()
    deadline = started + timeout_ms / 1000
    best = None
    while True:
        frame = await asyncio.to_thread(_current_frame)
        found = await asyncio.to_thread(vision.match, vision.gray(frame), target)
        best = found if best is None or found.score > best.score else best
        if (found.score >= min_score) != gone:
            elapsed = (time.monotonic() - started) * 1000
            what = "gone" if gone else f"found at ({found.x}, {found.y}) {found.width}x{found.height}"
            return [f"{template} {what}, score {found.score:.3f}, after {elapsed:.0f} ms", await _snapshot()]
        if time.monotonic() >= deadline:
            state = "still present" if gone else "not found"
            message = f"timeout: {template} {state}; best score {best.score:.3f} at ({best.x}, {best.y})"
            return [message, await _snapshot()]
        await asyncio.sleep(0.1)


@mcp.tool(structured_output=False)
@_errors
async def release_all() -> str:
    """Release every button and centre the sticks (agent and keyboard)."""
    app = await _app()
    await asyncio.to_thread(app.release_all)
    return "released"


async def _command(op: str, arg: str = "") -> int:
    app = await _app()
    return await asyncio.to_thread(app.command, op, arg)


@mcp.tool(structured_output=False)
@_errors
async def home(method: str = HOME_METHOD, snapshot_after_ms: int | None = 1500):
    """Go to the PS5 home screen (stands in for the PS button, which the pad cannot send).

    method: "suspend" (suspend the running game, as the PS button does), "system" or "shellcore".
    From system screens such as Settings, press circle instead.
    """
    if method not in p.HOME_METHODS:
        raise ValueError(f"method must be one of {', '.join(p.HOME_METHODS)}")
    status = await _command("home", method)
    return await _result(f"home ({method}): status {status & 0xFFFFFFFF:#x}", snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def close_app(snapshot_after_ms: int | None = 3000):
    """Close the running game or app (unsaved progress is lost). The console returns to the home screen."""
    status = await _command("close")
    return await _result(f"close: status {status & 0xFFFFFFFF:#x}", snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def launch(title_id: str, snapshot_after_ms: int | None = 5000):
    """Launch an installed title by id (e.g. PPSA01325). list_apps() shows what is installed.

    A game takes input only from the controller that launched it: launch it here to control it, because a game the
    user started with their own controller ignores this pad (and one launched here ignores theirs).
    """
    status = await _command("launch", title_id)
    text = "launched" if status == 0 else f"launch failed: status {status & 0xFFFFFFFF:#010x}"
    return await _result(f"{title_id}: {text}", snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def list_apps() -> list[str]:
    """Installed title ids (from /user/app on the console)."""
    from .probe_runner import Console
    entries = await asyncio.to_thread(Console(capture.console_host(HOST)).listdir, "/user/app")
    return sorted(e["name"] for e in entries if e.get("name", "").isalnum())


@mcp.tool(structured_output=False)
@_errors
async def uninstall_apps(title_ids: list[str]) -> list[str]:
    """DESTRUCTIVE: uninstall installed titles by id (e.g. ["PPSA01325"]); their data is deleted.

    Only uninstall what the user asked for by name. For titles ShadowMountPlus manages, their source folder or image
    is deleted too (otherwise it installs them again). The console refuses while a game is running; close_app first.
    Removal finishes in the background after each request is accepted. Needs padd 1.3 or later.
    """
    results = []
    for title_id in title_ids:
        try:
            deadline = time.monotonic() + 90
            while (status := await _command("uninstall", title_id)) in p.UNINSTALL_RETRY \
                    and time.monotonic() < deadline:
                await asyncio.sleep(2)
            results.append(f"{title_id}: {p.uninstall_text(status)}")
        except Exception as exc:  # noqa: BLE001 - one bad id must not hide the others' results
            results.append(f"{title_id}: {exc}")
    return results


@mcp.tool(structured_output=False)
@_errors
async def install(path: str, run: bool = False) -> str:
    """Install a file from this Mac onto the console.

    path: a .pkg package (uploaded through Web File Manager to /data/ps5-mcp/pkg, then installed; can take minutes)
    or an .elf payload (added to Payload Manager's library). run=True also starts the .elf once.
    """
    from . import installer
    return await asyncio.to_thread(installer.install, capture.console_host(HOST), Path(path), run, lambda _line: None)


@mcp.tool(structured_output=False)
@_errors
async def wait_for_change(timeout_ms: int = 3000, threshold: float = 6.0):
    """Wait until the screen changes (mean luma difference >= threshold on a 32x18 grid); returns the new frame."""
    await _app()
    start = time.monotonic()
    _, result = await asyncio.to_thread(runtime.capture.watch_change, threshold, timeout_ms / 1000)
    if not result.get("ok"):
        return ["no change within timeout", await _snapshot()]
    return [f"changed after {(result['changed_at'] - start) * 1000:.0f} ms (diff {result['diff']:.1f})",
            await _snapshot()]


@mcp.tool(structured_output=False)
@_errors
async def status() -> dict:
    """Payload link, payload version and counters, capture state and frame age."""
    app = await _app()
    # Right after startup the link may still be connecting; the app waits up to 1.5 s for it.
    hub = await asyncio.to_thread(app.call, "status", wait=1.5, timeout=5.0)
    link = hub["pad"]
    info: dict = {"payload": {"connected": link["connected"], "host": link["host"], "port": link["port"],
                              "error": link["error"], "reconnects": link["reconnects"],
                              "human_has_control": link["human_has_control"]}}
    for key in ("hello", "version"):
        if key in link:
            info["payload"][key] = link[key]
    if link["connected"]:
        with contextlib.suppress(PadError):
            info["payload"]["pong"] = await asyncio.to_thread(app.ping)
    info["capture"] = {"backend": "NativeApp", "running": True, "source": hub["source"],
                       "frame_age_s": hub["frame_age"] if hub["frame_age"] >= 0 else None}
    info["app"] = {"pid": hub["pid"], "clients": hub["clients"], "agents_holding": link["agent_layers"],
                   "visible": hub["visible"], "notice": hub["notice"], "padd": hub["padd"]}
    return info


@mcp.tool(structured_output=False)
@_errors
async def show_viewer() -> str:
    """Open the live video window for a human (keyboard in that window drives the console too)."""
    await _app()
    await asyncio.to_thread(runtime.capture.show)
    return "viewer shown"


def main() -> None:
    mcp.run("stdio")


if __name__ == "__main__":
    main()
