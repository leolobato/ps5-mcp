"""The PS5 app's local API against padd-host (stub pad), with a camera-free frame source (--video file:PATH)."""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest
from PIL import Image

from ps5mcp import capture
from ps5mcp import protocol as p
from ps5mcp.client import ConsoleInUse, HumanHasControl
from ps5mcp.hub import AppClient, AppError
from ps5mcp.protocol import PadState

from .test_padd_host import BINARY, Padd, wait_for

ROOT = Path(__file__).resolve().parents[1]
APP = capture.NATIVE_BINARY
DIALOG = ROOT / "tests/fixtures/assignment-dialog.png"
HOME = ROOT / "tests/fixtures/home-assigned.png"
RIGHT, CROSS, L1 = p.BUTTONS["right"], p.BUTTONS["cross"], p.BUTTONS["l1"]

pytestmark = pytest.mark.skipif(not (BINARY.exists() and APP.exists()), reason="run make (padd-host and the app)")

FAKE_CLI = """#!/bin/sh
# Stands in for `uv run ps5mcp`: records how it was called and checks that padd's slot is free.
echo "$@" > "$PS5MCP_STATE/cli-args"
"{python}" -c '
import os, sys
from ps5mcp.client import PadLink
link = PadLink("127.0.0.1", int(os.environ["FAKE_PADD_PORT"]))
print("slot free: hello", link.hello.pad_handle)
link.close()
' || echo "slot BUSY"
echo "running: results/20990101T000000Z-padd"
"""


def put_frame(path: Path, image: Image.Image | Path) -> None:
    """Replace the app's frame file atomically (the file source re-reads it on change)."""
    tmp = path.with_suffix(".tmp.png")
    (Image.open(image) if isinstance(image, Path) else image).convert("RGB").save(tmp, "PNG")
    os.replace(tmp, path)


class App:
    def __init__(self, padd: Padd, frame: Image.Image | Path | None = None, *args: str):
        self.padd = padd
        self.root = Path(tempfile.mkdtemp(prefix="a", dir="/tmp"))  # AF_UNIX paths are limited to ~104 bytes
        self.frame = self.root / "frame.png"
        put_frame(self.frame, frame or Image.new("RGB", (1920, 1080), (90, 90, 90)))
        cli = self.root / "fake-cli"
        cli.write_text(FAKE_CLI.replace("{python}", sys.executable))
        cli.chmod(0o755)
        self.log = self.root / "app.log"
        self.process = subprocess.Popen(
            [str(APP), "--state-dir", str(self.root), "--video", f"file:{self.frame}", "--audio", "none",
             "--headless", "--host", "127.0.0.1", "--port", str(padd.port), "--padd-cli", str(cli), *args],
            stdout=self.log.open("ab"), stderr=subprocess.STDOUT,
            env={**os.environ, "FAKE_PADD_PORT": str(padd.port), "PS5MCP_STATE": str(self.root)})
        self.clients: list[AppClient] = []
        deadline = time.monotonic() + 10
        while True:
            status = capture.NativeApp(self.root).status()
            if status and status["frames"] > 0 and status["pad"]["connected"]:
                break
            if time.monotonic() > deadline or self.process.poll() is not None:
                self.process.kill()
                raise RuntimeError(f"app did not come up: {status}\n{self.log.read_text()}")
            time.sleep(0.05)

    def client(self, name: str | None = None) -> AppClient:
        client = AppClient(self.root / "capture.sock", client=name)
        self.clients.append(client)
        return client

    def stop(self) -> None:
        for client in self.clients:
            client.close()
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            self.process.wait(5)
        shutil.rmtree(self.root, ignore_errors=True)


@pytest.fixture
def padd(tmp_path):
    daemon = Padd(tmp_path)
    yield daemon
    daemon.stop()


@pytest.fixture
def app(padd):
    hub = App(padd)
    yield hub
    hub.stop()


def buttons(padd) -> list[int]:
    return [c["buttons"] for c in padd.calls("pad_report")]


def test_status_reports_api_link_and_frames(app):
    status = app.client().status()
    assert status["api"] == 1 and status["frames"] > 0 and 0 <= status["frame_age"] < 1
    assert status["pad"]["connected"] and status["pad"]["version"] == "1.3"
    assert status["pad"]["hello"]["pad_handle"] == 1000 and status["source"].startswith("file:")
    assert status["pad"]["hello"]["user_name"] == "Test Player"
    assert status["title"] == "PS5 MCP · pad connected"


def test_legacy_capture_socket_still_works(app):
    native = capture.NativeApp(app.root)
    assert native.pid() == app.process.pid and native.frame_age() < 1
    out = capture.snapshot(app.root / "snap.jpg", daemon=native)
    assert Image.open(out).size == (1920, 1080)


def test_set_reaches_pad_and_neutral_releases(app):
    agent = app.client("agent")
    agent.set(PadState(buttons=RIGHT, lx=0))
    assert wait_for(lambda: buttons(app.padd)[-1] == RIGHT)
    assert app.padd.calls("pad_report")[-1]["lx"] == 0
    agent.set(PadState())
    assert wait_for(lambda: buttons(app.padd)[-1] == 0)


def test_two_clients_merge_without_busy(app):
    first, second = app.client("one"), app.client("two")
    first.set(PadState(buttons=RIGHT))
    second.set(PadState(buttons=CROSS))
    assert wait_for(lambda: buttons(app.padd)[-1] == RIGHT | CROSS)
    first.release()
    assert wait_for(lambda: buttons(app.padd)[-1] == CROSS)
    assert app.client().status()["pad"]["agent_layers"] == 1


def test_closing_a_client_releases_only_its_input(app):
    leaving, staying = app.client("leaving"), app.client("staying")
    leaving.set(PadState(buttons=RIGHT))
    staying.set(PadState(buttons=L1))
    assert wait_for(lambda: buttons(app.padd)[-1] == RIGHT | L1)
    leaving.close()
    assert wait_for(lambda: buttons(app.padd)[-1] == L1)
    staying.set(PadState(buttons=CROSS))
    assert wait_for(lambda: buttons(app.padd)[-1] == CROSS)


def test_held_key_blocks_agents_and_release_hands_back(app):
    agent, keyboard = app.client("agent"), app.client()
    agent.set(PadState(buttons=RIGHT))
    assert wait_for(lambda: buttons(app.padd)[-1] == RIGHT)
    keyboard.key("enter", True)
    assert wait_for(lambda: buttons(app.padd)[-1] == CROSS)  # the agent hold is cancelled
    assert app.client().status()["pad"]["human_has_control"]
    with pytest.raises(HumanHasControl):
        agent.set(PadState(buttons=RIGHT))
    with pytest.raises(HumanHasControl):
        agent.press(PadState(buttons=RIGHT), 50)
    agent.set(PadState())  # neutral is always allowed
    keyboard.key("enter", False)
    assert wait_for(lambda: buttons(app.padd)[-1] == 0)
    assert wait_for(lambda: not app.client().status()["pad"]["human_has_control"])
    agent.press(PadState(buttons=RIGHT), 40)
    assert buttons(app.padd)[-2:] == [RIGHT, 0]


def test_quick_key_tap_lasts_80_ms(app):
    events: list[tuple[float, int]] = []
    watcher = app.client()
    watcher.on("state", lambda e: events.append((e["t"], e["state"]["buttons"])))
    watcher.subscribe("state")
    keyboard = app.client()
    keyboard.key("down", True)  # down and up at once: a synthetic 0 ms tap
    keyboard.key("down", False)
    assert wait_for(lambda: len(events) >= 2)
    (down_at, pressed), (up_at, released) = events[:2]
    assert pressed == p.BUTTONS["down"] and released == 0
    assert 0.075 <= up_at - down_at < 0.2
    assert wait_for(lambda: buttons(app.padd)[-1] == 0)


def test_unmapped_key_is_an_error(app):
    with pytest.raises(AppError, match="unmapped"):
        app.client().key("f13", True)


def test_hold_survives_the_watchdog(app):
    app.client("agent").set(PadState(buttons=RIGHT))
    time.sleep(1.5)
    assert buttons(app.padd)[-1] == RIGHT
    assert {"event": "neutral", "reason": "watchdog"} not in app.padd.events()


def test_press_holds_then_releases_with_gap(app):
    started = time.monotonic()
    app.client("agent").press(PadState(buttons=RIGHT), 100)
    elapsed = time.monotonic() - started
    assert buttons(app.padd)[-2:] == [RIGHT, 0]
    assert 0.16 <= elapsed < 0.5  # 100 ms hold + 60 ms release gap


def test_press_validates_duration(app):
    with pytest.raises(AppError, match="duration"):
        app.client().press(PadState(buttons=RIGHT), 60_000)


def test_commands_and_ping(app):
    client = app.client()
    assert client.command("home", "suspend") == 0
    assert client.command("close") == 0
    assert client.command("launch", "BADTITLE") == -0x7F6BFFFB
    with pytest.raises(AppError, match="method must be"):
        client.command("home", "bogus")
    assert app.padd.calls("go_home")[-1]["method"] == "suspend"
    assert client.ping()["report_failures"] == 0


def test_uninstall_goes_through_the_app(app):
    client = app.client()
    assert client.command("uninstall", "PPSA01325") == 0
    assert client.command("uninstall", "BUSY00001") == -0x7F5CFFFB
    with pytest.raises(AppError, match="title id"):
        client.command("uninstall", "PPSA")
    assert [c["title_id"] for c in app.padd.calls("uninstall")] == ["PPSA01325", "BUSY00001"]


def test_home_key_sends_home_command(app):
    app.client().key("h", True)
    assert wait_for(lambda: app.padd.calls("go_home"))
    assert app.padd.calls("go_home")[-1]["method"] == "suspend"


def test_watch_change_fires_when_the_frame_changes(app):
    native = capture.NativeApp(app.root)
    result: dict = {}
    thread = threading.Thread(target=lambda: result.update(native.watch_change(threshold=6, timeout=3)[1]))
    thread.start()
    time.sleep(0.3)
    put_frame(app.frame, Image.new("RGB", (1920, 1080), (230, 230, 230)))
    thread.join()
    assert result["ok"] and result["diff"] > 6


def test_reconnects_neutral_after_padd_restarts(app, tmp_path):
    client = app.client("agent")
    client.set(PadState(buttons=RIGHT))
    app.padd.stop()
    assert wait_for(lambda: not client.status()["pad"]["connected"])
    restarted = subprocess.Popen([str(BINARY), "--port", str(app.padd.port), "--log-dir", str(tmp_path / "logs2")],
                                 env={"PADD_TRACE": str(tmp_path / "trace2.jsonl")})
    try:
        assert wait_for(lambda: client.status()["pad"]["connected"], 8)
        assert client.call("state")["state"]["buttons"] == 0
        assert client.status()["pad"]["reconnects"] >= 1
    finally:
        restarted.send_signal(signal.SIGTERM)
        restarted.wait(5)


def test_padd_start_pauses_the_link_for_the_cli(app):
    client = app.client()
    result = client.call("padd_start", firmware="13.60", timeout=20)
    assert result["status"] == "running" and result["run"] == "results/20990101T000000Z-padd"
    assert "slot free: hello 1000" in result["output"]
    assert (app.root / "cli-args").read_text().split() == ["padd", "start", "--host", "127.0.0.1",
                                                         "--firmware", "13.60"]
    assert wait_for(lambda: client.status()["pad"]["connected"], 5)  # resumed
    assert client.status()["padd"]["last"]["action"] == "start"


def test_status_events_follow_the_link(app):
    seen: list[dict] = []
    client = app.client()
    client.on("status", seen.append)
    client.subscribe("status")
    assert wait_for(lambda: seen)
    app.padd.stop()
    assert wait_for(lambda: any(not e["pad"]["connected"] for e in seen))


def test_quit_releases_input_and_leaves_padd_running(app):
    app.client("agent").set(PadState(buttons=RIGHT))
    assert wait_for(lambda: buttons(app.padd)[-1] == RIGHT)
    capture.NativeApp(app.root).request("quit")
    assert app.process.wait(5) == 0
    assert wait_for(lambda: buttons(app.padd)[-1] == 0)
    assert app.padd.process.poll() is None and not app.padd.calls("pad_remove")
    assert not (app.root / "capture.sock").exists()


@pytest.mark.skipif(not (DIALOG.exists() and HOME.exists()), reason="test fixtures not present")
def test_auto_assign_presses_cross_only_when_the_dialog_shows(padd):
    hub = App(padd, DIALOG)
    try:
        assert wait_for(lambda: CROSS in buttons(padd), 4)
        put_frame(hub.frame, HOME)  # the dialog goes away once answered
        assert wait_for(lambda: "Who's using this controller" in (hub.client().status()["notice"] or ""), 4)
        assert buttons(padd).count(CROSS) == 1 and buttons(padd)[-1] == 0
        assert (hub.root / "auto-assign-before.jpg").exists() and (hub.root / "auto-assign-after.jpg").exists()
    finally:
        hub.stop()


@pytest.mark.skipif(not HOME.exists(), reason="test fixtures not present")
def test_auto_assign_never_presses_without_the_dialog(padd):
    hub = App(padd, HOME)
    try:
        time.sleep(2.5)
        assert CROSS not in buttons(padd)
    finally:
        hub.stop()


def test_record_events_capture_keys_and_agents(app):
    from ps5mcp.hub import state_from_json
    from ps5mcp.recording import Recorder
    recorder = Recorder()
    watcher = app.client()
    watcher.on("state", lambda e: recorder.note(state_from_json(e["state"]), e["t"]))
    watcher.subscribe("state")
    app.client("agent").press(PadState(buttons=p.BUTTONS["triangle"]), 50)
    keyboard = app.client()
    keyboard.key("left", True)
    time.sleep(0.1)
    keyboard.key("left", False)
    assert wait_for(lambda: len(recorder.changes) >= 4)
    steps = recorder.steps()
    assert [s.get("buttons") for s in steps if s.get("buttons")] == [["triangle"], ["left"]]
    assert json.dumps(steps)


def test_claim_blocks_other_agents_and_queues_them(app):
    holder, waiter, bystander = app.client("holder"), app.client("waiter"), app.client("bystander")
    assert holder.claim("menu test")["granted"]
    holder.press(PadState(buttons=RIGHT), 30)
    with pytest.raises(ConsoleInUse, match='holder \\("menu test"\\)'):
        bystander.press(PadState(buttons=CROSS), 30)
    with pytest.raises(ConsoleInUse):
        bystander.command("home")
    bystander.set(PadState())  # letting go is always allowed
    queued = waiter.claim("next")
    assert not queued["granted"] and queued["position"] == 1 and queued["owner"]["client"] == "holder"
    assert waiter.claim("next")["position"] == 1  # claiming again keeps the place
    status = bystander.status()["lease"]
    assert status["owner"]["reason"] == "menu test" and [q["client"] for q in status["queue"]] == ["waiter"]
    events = []
    bystander.on("status", events.append)
    bystander.subscribe("status")
    assert holder.unclaim()["released"]
    assert waiter.lease()["granted"]
    assert wait_for(lambda: any((e["lease"]["owner"] or {}).get("client") == "waiter" for e in events))
    waiter.press(PadState(buttons=CROSS), 30)
    with pytest.raises(ConsoleInUse):
        holder.press(PadState(buttons=RIGHT), 30)


def test_keyboard_still_wins_over_a_claim(app):
    agent, window = app.client("agent"), app.client()
    agent.claim("busy")
    window.key("enter", True)
    assert wait_for(lambda: buttons(app.padd)[-1] == CROSS)
    with pytest.raises(HumanHasControl):
        agent.press(PadState(buttons=RIGHT), 30)
    window.key("enter", False)


def test_closing_the_holder_passes_the_claim_on(app):
    leaving, waiting = app.client("leaving"), app.client("waiting")
    leaving.claim("a")
    assert waiting.claim("b")["position"] == 1
    leaving.close()
    assert wait_for(lambda: waiting.lease()["granted"])
    waiting.close()
    assert wait_for(lambda: app.client().status()["lease"]["owner"] is None)


def test_idle_claim_lapses_to_the_next_in_queue(app):
    idle, waiting = app.client("idle"), app.client("waiting")
    idle.claim("forgot", idle_s=10)  # 10 s is the minimum
    waiting.claim("b")
    assert not waiting.lease()["granted"]
    assert wait_for(lambda: waiting.lease()["granted"], timeout=15)


def test_user_name_failure_does_not_block_app_connection(tmp_path):
    daemon = Padd(tmp_path, env={"PADD_FAIL_USER_NAME": "38"})
    try:
        app = App(daemon)
        try:
            status = app.client().status()
            assert status["pad"]["connected"]
            assert status["pad"]["hello"]["user_name"] is None
            assert status["pad"]["hello"]["user_id"] == 0x11ECF8B9
        finally:
            app.stop()
    finally:
        daemon.stop()
