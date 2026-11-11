"""ps5-mcp MCP server (stdio): see the PS5 through the capture card, drive it through padd.

A thin client of the PS5 app (app/*.swift), which owns the capture card and the only padd connection. Several
servers (and the keyboard in the app window) can drive the console at once; the app merges their input. If the
app is not running, the server launches it: headless, or visible with PS5MCP_VIEW=1.

Environment: PS5_HOST (the console's IP address, required), PS5MCP_VIEW=1, PS5MCP_STATE (the app's state dir),
PS5MCP_FTP=0 (no push/pull tools), PS5MCP_FTP_PORT, PS5MCP_FTP_AUTOSTART=0 (never start zftpd; see transfer.py).
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import tempfile
import threading
import time
from collections.abc import AsyncIterator
from importlib.metadata import version
from pathlib import Path

from mcp.server.mcpserver import Image, MCPServer

from . import capture, recording, stream, vision
from . import protocol as p
from .client import ConsoleInUse, HumanHasControl, PadError
from .hub import AppClient, state_from_json
from .probe_runner import ConsoleError
from .protocol import PadState

HOST = os.environ.get("PS5_HOST")
MAX_HOLD_MS = 10_000
MAX_CLAIM_WAIT_S = 600
HOME_METHOD = os.environ.get("PS5MCP_HOME_METHOD", "suspend")
# The PS5 drops a press that follows a release too closely (seen on 13.60 with 0 ms gaps), so every hold ends
# with this much neutral before the tool returns. The app's `press` adds it; `sequence` adds it here.
RELEASE_GAP_S = 0.06
# How long input and console commands wait for the app's padd link. When the Mac loses the link without padd seeing
# it close (a network blip), padd rejects the app's reconnects as busy until it drops the silent session after its
# 5 s idle limit; waiting past that lets the tool ride out the reconnect instead of failing.
LINK_WAIT_S = 8.0


class Runtime:
    def __init__(self):
        self.capture: capture.NativeApp | None = None
        self.stream = None
        self.recorder: recording.Recorder | None = None
        self._app: AppClient | None = None
        self._lock = threading.Lock()
        self.title_uploads: dict[str, str] = {}

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
        "Cross confirms, circle goes back. ps_button() opens the control center, and a one-second hold goes home; "
        "home() suspends the running game. When Remote Play is the video source, type_text() fills text fields. "
        "If a tool says a human has control, wait and retry. "
        "The console is shared with other agents: call claim_console(reason) before a task so nobody interrupts "
        "you, and release_console() when done. If a tool says the PS5 is in use, call claim_console(reason, "
        "wait_s=...) to queue; it returns when the console is yours (call it again to keep waiting)."
    ),
    lifespan=lifespan,
)


def _looking() -> None:
    """Frames come over a separate socket, so tell the app on ours: looking keeps a claim alive."""
    runtime.app().lease()  # the app owns the card; never fall back to opening it here


def _frame(max_width: int | None) -> Image:
    _looking()
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
    """Hold `state`, release, then the release gap; the app times it (waiting up to LINK_WAIT_S for the padd link)."""
    _check_duration(duration_ms)
    app = await _app()
    await asyncio.to_thread(app.press, state, duration_ms, LINK_WAIT_S)


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
        except ConsoleInUse as exc:
            return f"in use: {exc}"
        except (PadError, capture.CaptureError, ConsoleError, ValueError) as exc:
            return f"error: {exc}"
    return wrapper


@mcp.tool(structured_output=False)
@_errors
async def snapshot(max_width: int = 1280) -> Image:
    """Current PS5 screen as a JPEG (scaled to max_width; the source is 1920x1080)."""
    return await _snapshot(max_width)


@mcp.tool(structured_output=False)
@_errors
async def frame_meter(on: bool = True) -> dict:
    """Turn the game frame rate meter on or off. Capture card only. While it is on, status() has capture.frame_meter:
    state (starting, measuring, static, no_signal), fps, low_1pct_fps, gaps (frames lost on the Mac side, not measured),
    refresh_ms and the recent frame_times_ms. It compares captured frames, so it cannot see above 60 fps, frame times are
    multiples of about 16.7 ms, a game without vsync reads high, and a very slow scene may read low. A frame one refresh
    long and one a refresh short close together count as even frames: it is mostly clock drift between console and card."""
    app = await _app()
    reply = await asyncio.to_thread(app.call, "frame_meter", on=on)
    return {"on": on, "frame_meter": reply["frame_meter"]}


@mcp.tool(structured_output=False)
@_errors
async def measure_frame_rate(seconds: float = 10.0) -> dict:
    """Measure the game's frame rate for a fixed period (1 to 600 seconds) and return once it ends, about a second later
    if the meter was off. Capture card only. It sends no input and needs no claim, so run it beside the actions that
    keep the picture moving. Returns fps (average over the moving time), low_1pct_fps (null under 100 frame times),
    new_frames, frame_times (count per frame time in ms), static_seconds (a still picture is not counted in fps), gaps
    (frames lost on the Mac side), state (measuring, static, no_signal), seconds and complete (false if the signal ended
    early). Same limits as frame_meter: nothing above 60 fps, and frame times are multiples of about 16.7 ms."""
    app = await _app()
    reply = await asyncio.to_thread(app.call, "measure_frame_rate", seconds=float(seconds), timeout=seconds + 10)
    reply.pop("ok", None)
    return reply


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
            await asyncio.to_thread(app.set, state, LINK_WAIT_S if index == 0 else 0.0)
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
    _looking()
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
    """Wait until a saved template image appears on screen (or disappears, with gone=true).

    template: the name of an image saved with save_template (list_templates shows them). This matches pixels, not
    text: there is no OCR, so to wait for some text, first save_template a region of the screen that shows it.
    timeout_ms is in milliseconds. Matching is normalised cross-correlation over the whole frame; score 1.0 is
    identical. Returns where it was found, the score and the frame. For any change at all, use wait_for_change.
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
    return await asyncio.to_thread(app.command, op, arg, LINK_WAIT_S)


@mcp.tool(structured_output=False)
@_errors
async def home(method: str = HOME_METHOD, snapshot_after_ms: int | None = 1500):
    """Go to the PS5 home screen by suspending the running game, without pressing anything (see also ps_button()).

    method: "suspend" (suspend the running game, as the PS button does), "system" or "shellcore".
    From system screens such as Settings, press circle instead.
    """
    if method not in p.HOME_METHODS:
        raise ValueError(f"method must be one of {', '.join(p.HOME_METHODS)}")
    status = await _command("home", method)
    return await _result(f"home ({method}): status {status & 0xFFFFFFFF:#x}", snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def ps_button(hold_ms: int = 100, snapshot_after_ms: int | None = 1000):
    """Press the PS button on the selected controller; a tap opens the control center and a second tap closes it.

    Holding about a second goes to the home screen. hold_ms: 1..2000. The control center includes Power: never choose
    Restart or Turn Off unless the user asked for it.
    """
    if not 0 < hold_ms <= 2000:
        raise ValueError("hold_ms must be 1..2000")
    await _apply_for(PadState(buttons=p.button_mask(["ps"])), hold_ms)
    return await _result(f"pressed PS for {hold_ms} ms", snapshot_after_ms)


KEYBOARD_RESULTS = {
    "confirmed": "the PS5 shows the text",
    "differs": "the PS5 changed the text (for example a length limit); check the snapshot",
    "closed": "the keyboard closed before the PS5 answered",
    "timeout": "the PS5 did not answer; check the snapshot",
}


@mcp.tool(structured_output=False)
@_errors
async def type_text(text: str, submit: bool = False, snapshot_after_ms: int | None = 500):
    """Fill the PS5 text field whose on-screen keyboard is open (only while Remote Play is the video source).

    Select a text field first (cross on it) so the keyboard shows. The text replaces the field's content; it is not
    appended. submit=True closes the keyboard and keeps the text once the PS5 shows it. Up to 1024 UTF-8 bytes.
    The PS5 shows "Use the keyboard on your Remote Play device" instead of its own keyboard while this is possible;
    close_keyboard() hands the field back to its normal keyboard.
    """
    app = await _app()
    reply = await asyncio.to_thread(app.keyboard_text, text, submit)
    message = f"typed {len(text)} characters: {KEYBOARD_RESULTS.get(reply['result'], reply['result'])}"
    if submit:
        message += "; submitted" if reply["submitted"] else "; not submitted"
    return await _result(message, snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def close_keyboard(accept: bool = False, snapshot_after_ms: int | None = 500):
    """Finish Remote Play text entry: accept=True keeps the text and closes the keyboard; False keeps the text and
    shows the PS5's own on-screen keyboard again (for press(), or a controller)."""
    app = await _app()
    await asyncio.to_thread(app.keyboard_close, accept)
    return await _result("keyboard closed" if accept else "keyboard handed back to the PS5", snapshot_after_ms)


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
    if reason := runtime.title_uploads.get(title_id):
        return f"{title_id}: launch blocked: {reason}"
    status = await _command("launch", title_id)
    text = "launched" if status == 0 else f"launch failed: status {status & 0xFFFFFFFF:#010x}"
    return await _result(f"{title_id}: {text}", snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def connect_controller(user_id: int | None = None, snapshot_after_ms: int | None = 3000):
    """Add a virtual controller for local multiplayer tests, up to 4 in all (padd 1.9; 2 in all before it).

    Controller 1 is the foreground user's. Each added one is for the next signed-in user with no controller (a game's
    next player). Sign that user (or a guest) in on the console first. Connecting selects the new controller, so every
    input tool drives it, and the app answers its "Who's using this controller?". status() shows them under
    payload.controllers, with the users still free under available.

    user_id: add it for that user instead. For a user who is not signed in, the app answers the dialog on that user's
    profile, which signs them in. Users seen signed in before are listed under payload.controllers.signed_out.

    If status() shows a notice asking to pick the user, the app could not find the profile: the dialog opens on the
    first signed-in profile, so move to the right one before press("cross"). On the home screen the console follows
    one user's controller; ps_button(hold_ms=1000) on the new controller takes over.
    """
    if user_id is not None and not 0 < user_id < 2**31:
        raise ValueError("user_id must be a positive user id")
    status = await _command("pad", f"connect {user_id}" if user_id else "connect")
    if status != 0:
        return f"new controller: {p.pads_text('pad', status)}"
    return await _result(await _controllers_text(), snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def disconnect_controller(controller: int | None = None, snapshot_after_ms: int | None = 3000):
    """Remove an added controller: number 2 to 4, or the highest one when omitted. Controller 1 stays.

    If input was going to it, input goes back to controller 1. The other controllers keep their numbers.
    """
    if controller is not None and not 2 <= controller <= p.MAX_CONTROLLERS:
        raise ValueError(f"controller must be 2 to {p.MAX_CONTROLLERS}")
    status = await _command("pad", f"disconnect {controller}" if controller else "disconnect")
    if status != 0:
        return f"controller {controller}: {p.pads_text('pad', status)}"
    return await _result(await _controllers_text(), snapshot_after_ms)


@mcp.tool(structured_output=False)
@_errors
async def use_controller(controller: int, snapshot_after_ms: int | None = None):
    """Send input (press, stick, sequence, ...) to controller 1 to 4 from now on.

    It is the same choice as the window's "Input to" menu, and it stays for everyone using the app. The other
    controllers are released. The controller must be connected first (connect_controller).
    """
    if not 1 <= controller <= p.MAX_CONTROLLERS:
        raise ValueError(f"controller must be 1 to {p.MAX_CONTROLLERS}")
    status = await _command("select_pad", str(controller))
    if status != 0:
        return f"controller {controller}: {p.pads_text('select_pad', status)}"
    return await _result(await _controllers_text(), snapshot_after_ms)


async def _controllers_text() -> str:
    controllers = (await asyncio.to_thread((await _app()).status)).get("controllers") or {}
    def user(c: dict) -> str:
        return "no user" if c["user_id"] < 0 else str(c.get("user_name") or c["user_id"])

    names = ", ".join(f"controller {c['controller']} = {user(c)}" for c in controllers.get("list", []))
    return f"input goes to controller {controllers.get('active', 1)} ({names})"


@mcp.tool(structured_output=False)
@_errors
async def list_apps() -> list[str]:
    """Installed title ids (from /user/app on the console, read through PS5 Web File Manager on port 8888)."""
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
    """Install a file from this Mac onto the console (refused while another agent has claimed it).

    path: a .pkg package (uploaded through Web File Manager to /data/ps5-mcp/pkg, then installed; can take minutes)
    or an .elf payload (added to Payload Manager's library). run=True also starts the .elf once.
    """
    from . import installer
    await _check_claim()  # the upload bypasses the app, so check the claim here
    return await asyncio.to_thread(installer.install, capture.console_host(HOST), Path(path), run, lambda _line: None)


async def _check_claim() -> None:
    app = await _app()
    lease = await asyncio.to_thread(app.lease)
    if lease["owner"] and not lease["granted"]:
        raise ConsoleInUse(f"the PS5 is in use by {_holder(lease)}; call claim_console to queue for it")


def _transfer_tool(fn):
    """push/pull are tools unless PS5MCP_FTP=0; transfer failures come back as tool text."""
    import ftplib
    import functools

    @functools.wraps(fn)
    async def wrapper(*args, **kwargs):
        try:
            return await fn(*args, **kwargs)
        except (PadError, capture.CaptureError):
            raise  # "in use" and the rest of _errors' wording
        except (RuntimeError, OSError, ftplib.Error) as exc:
            return f"error: {exc}"
    wrapper = _errors(wrapper)
    return mcp.tool(structured_output=False)(wrapper) if os.environ.get("PS5MCP_FTP", "1") != "0" else wrapper


@_transfer_tool
async def push(local_path: str, remote_path: str, force: bool = False) -> str:
    """Copy a file or folder from this Mac to the console (refused while another agent has claimed it).

    Uses FTP through zftpd (port 2120), starting it from Payload Manager when it is not running; without zftpd,
    files go one at a time through Web File Manager. remote_path is absolute and names the destination itself;
    end it with "/" to copy into that folder. Unchanged files (same size, not newer here) are skipped and partial
    ones resumed; force=True sends everything again. Native executables/modules are chmodded to 0755 and
    remote execute bits verified, including skipped files (requires zftpd). Native title folders with a PS5
    manifest also wait for ShadowMount registration through its LAN-accessible API (port 10101 or
    PS5MCP_SMP_PORT). Failed title uploads block launch in this server session until push succeeds.
    """
    from . import transfer
    await _check_claim()
    source = Path(local_path).expanduser()
    target = transfer._target(remote_path, source.name)
    titles = transfer.native_titles(source, target)
    if any(runtime.title_uploads.get(title_id) == "title upload in progress" for title_id, _ in titles):
        raise RuntimeError("a title upload is already in progress; wait for it to finish")
    for title_id, _ in titles:
        runtime.title_uploads[title_id] = "title upload in progress"
    complete = False
    try:
        result = await asyncio.to_thread(transfer.push, capture.console_host(HOST), local_path, remote_path,
                                        lambda _line: None, force=force)
        complete = True
        return result
    finally:
        for title_id, _ in titles:
            if complete:
                runtime.title_uploads.pop(title_id, None)
            else:
                runtime.title_uploads[title_id] = "title upload checks incomplete; retry push before launch"


@_transfer_tool
async def pull(remote_path: str, local_path: str, force: bool = False) -> str:
    """Copy a file or folder from the console to this Mac.

    Uses FTP through zftpd (port 2120), starting it from Payload Manager when it is not running (that start is
    refused while another agent has claimed the console); without zftpd, only single files can be copied.
    If local_path is an existing folder or ends with "/", the item is copied into it. Unchanged files are skipped
    and partial ones resumed; force=True copies everything again.
    """
    from . import transfer

    def before_start() -> None:
        asyncio.run_coroutine_threadsafe(_check_claim(), loop).result()

    loop = asyncio.get_running_loop()
    return await asyncio.to_thread(transfer.pull, capture.console_host(HOST), remote_path, local_path,
                                   lambda _line: None, force=force, before_start=before_start)


@mcp.tool(structured_output=False)
@_errors
async def wait_for_change(timeout_ms: int = 3000, threshold: float = 6.0):
    """Wait until the screen changes (mean luma difference >= threshold on a 32x18 grid); returns the new frame."""
    await _app()
    await asyncio.to_thread(_looking)
    start = time.monotonic()
    _, result = await asyncio.to_thread(runtime.capture.watch_change, threshold, timeout_ms / 1000)
    if not result.get("ok"):
        return ["no change within timeout", await _snapshot()]
    return [f"changed after {(result['changed_at'] - start) * 1000:.0f} ms (diff {result['diff']:.1f})",
            await _snapshot()]


@mcp.tool(structured_output=False)
@_errors
async def status() -> dict:
    """Payload link, payload version and counters, capture state and frame age, and the app's version (app.padd.bundled
    is the padd version the app deploys). payload.controllers (padd 1.7): which controller input drives (active) and
    each connected controller's user (see connect_controller). payload.login_users: the foreground user's id and the
    signed-in users' ids and names."""
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
    info["payload"]["controllers"] = hub.get("controllers")
    info["payload"]["login_users"] = hub.get("login_users")
    if link["connected"]:
        with contextlib.suppress(PadError):
            info["payload"]["pong"] = await asyncio.to_thread(app.ping)
    info["capture"] = {"backend": "NativeApp", "running": True, "source": hub["source"],
                       "frame_age_s": hub["frame_age"] if hub["frame_age"] >= 0 else None}
    if hub.get("remote_play"):
        info["capture"]["remote_play"] = hub["remote_play"]  # state, readiness, keyboard.open for type_text
    if hub.get("frame_meter"):
        info["capture"]["frame_meter"] = hub["frame_meter"]
    info["app"] = {"version": hub.get("version"), "build": hub.get("build"), "server_version": version("ps5-mcp"),
                   "pid": hub["pid"], "clients": hub["clients"], "agents_holding": link["agent_layers"],
                   "visible": hub["visible"], "notice": hub["notice"], "padd": hub["padd"]}
    lease = await asyncio.to_thread(app.lease)
    info["claim"] = {"held_by_you": lease["granted"], "queue_position": lease["position"] if lease["position"] > 0
                     else None, "owner": lease["owner"], "queue": lease["queue"]}
    return info


def _holder(lease: dict) -> str:
    owner = lease["owner"]
    reason = f' ("{owner["reason"]}")' if owner["reason"] else ""
    return f"{owner['client']}{reason}, holding it for {owner['held_s']:.0f} s"


@mcp.tool(structured_output=False)
@_errors
async def claim_console(reason: str, wait_s: int = 0, idle_timeout_s: int = 600) -> str:
    """Reserve the PS5 so other agents cannot drive it until you call release_console().

    reason: what you are doing, shown to other agents and in the app window. If another agent holds the console you
    join the queue; with wait_s > 0 (up to 600) this waits for your turn. Calling it again keeps your place, so call
    it again to keep waiting. The claim lapses after idle_timeout_s (10..3600, default 600) without a tool call from
    you, and when this session or the app ends; status() shows claim.held_by_you. Looking (snapshot, status) needs
    no claim; humans at the keyboard always win.
    """
    if not 0 <= wait_s <= MAX_CLAIM_WAIT_S:
        raise ValueError(f"wait_s must be 0..{MAX_CLAIM_WAIT_S}")
    app = await _app()
    deadline = time.monotonic() + wait_s
    while True:
        lease = await asyncio.to_thread(app.claim, reason, idle_timeout_s)
        if lease["granted"]:
            return (f"the PS5 is yours; call release_console() when done "
                    f"(lapses after {lease['owner']['expires_in_s']:.0f} s without a tool call)")
        if time.monotonic() >= deadline:
            return (f"queued #{lease['position']} behind {_holder(lease)}; call claim_console again "
                    "(with wait_s) to keep waiting, your place is kept")
        await asyncio.sleep(0.5)


@mcp.tool(structured_output=False)
@_errors
async def release_console() -> str:
    """Give up your claim on the PS5 (or your place in the queue); the next agent in the queue gets it."""
    app = await _app()
    lease = await asyncio.to_thread(app.unclaim)
    if not lease["released"]:
        return "you had no claim"
    return "released" + (f"; now held by {_holder(lease)}" if lease["owner"] else "")


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
