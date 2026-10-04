"""MCP tools end to end: the thin server over the PS5 app, against padd-host (stub pad) and a file frame source."""

from __future__ import annotations

import asyncio
import json

import pytest

from ps5mcp import protocol as p
from ps5mcp import server

from .test_app import APP, App, put_frame
from .test_padd_host import BINARY, Padd, wait_for

pytestmark = pytest.mark.skipif(not (BINARY.exists() and APP.exists()), reason="run make (padd-host and the app)")


@pytest.fixture
def hub(tmp_path, monkeypatch):
    daemon = Padd(tmp_path)
    app = App(daemon)
    monkeypatch.setenv("PS5MCP_STATE", str(app.root))
    monkeypatch.setattr(server, "runtime", server.Runtime())
    server.runtime.start()
    yield app
    server.runtime.stop()
    app.stop()
    daemon.stop()


@pytest.fixture
def runtime(hub):
    return hub.padd


def text(result) -> str:
    blocks = result.content if hasattr(result, "content") else result
    return " ".join(getattr(b, "text", "") for b in blocks)


def kinds(result) -> list[str]:
    blocks = result.content if hasattr(result, "content") else result
    return [b.type for b in blocks]


def reports(daemon) -> list[int]:
    return [c["buttons"] for c in daemon.calls("pad_report")]


async def test_press_reaches_pad_then_releases(runtime):
    result = await server.mcp.call_tool("press", {"button": "right", "hold_ms": 60})
    assert "pressed right" in text(result)
    assert p.BUTTONS["right"] in reports(runtime) and reports(runtime)[-1] == 0


async def test_press_can_return_a_frame(runtime):
    result = await server.mcp.call_tool("press", {"button": "cross", "snapshot_after_ms": 10})
    assert kinds(result) == ["text", "image"]


async def test_unknown_button_is_a_readable_error(runtime):
    assert "unknown button" in text(await server.mcp.call_tool("press", {"button": "ps"}))


async def test_hold_sequence_stick_trigger(runtime):
    await server.mcp.call_tool("hold", {"buttons": ["l1", "r1"], "duration_ms": 50})
    assert p.BUTTONS["l1"] | p.BUTTONS["r1"] in reports(runtime)
    await server.mcp.call_tool("sequence", {"steps": [{"buttons": ["up"], "duration_ms": 40},
                                                      {"duration_ms": 40}, {"lx": -1, "duration_ms": 40}]})
    assert p.BUTTONS["up"] in reports(runtime)
    assert any(c["lx"] == 0 for c in runtime.calls("pad_report"))
    await server.mcp.call_tool("trigger", {"side": "right", "value": 1, "duration_ms": 40})
    assert any(c["r2"] == 255 and c["buttons"] == p.BUTTONS["r2"] for c in runtime.calls("pad_report"))
    await server.mcp.call_tool("stick", {"side": "right", "x": 0, "y": 1, "duration_ms": 40})
    assert any(c["ry"] == 255 for c in runtime.calls("pad_report"))
    last = runtime.calls("pad_report")[-1]
    assert last["buttons"] == 0 and last["lx"] == last["ry"] == 0x80


async def test_overlong_hold_is_refused(runtime):
    assert "duration" in text(await server.mcp.call_tool("hold", {"buttons": ["up"], "duration_ms": 60_000}))


async def test_home_and_launch_commands(runtime):
    assert "home (suspend): status 0x0" in text(await server.mcp.call_tool("home", {"snapshot_after_ms": None}))
    assert "method must be" in text(await server.mcp.call_tool("home", {"method": "x", "snapshot_after_ms": None}))
    assert "close: status 0x0" in text(await server.mcp.call_tool("close_app", {"snapshot_after_ms": None}))
    assert "launch failed: status 0x80940005" in text(
        await server.mcp.call_tool("launch", {"title_id": "BADTITLE", "snapshot_after_ms": None}))


async def test_status_reports_link_and_counters(runtime):
    info = json.loads(text(await server.mcp.call_tool("status", {})))
    assert info["payload"]["connected"] and info["payload"]["version"] == "1.3"
    assert info["payload"]["pong"]["report_failures"] == 0
    assert info["capture"]["running"]


async def test_snapshot_returns_jpeg(runtime):
    result = await server.mcp.call_tool("snapshot", {"max_width": 320})
    assert kinds(result) == ["image"]


async def test_human_keyboard_blocks_agent_until_released(hub):
    runtime = hub.padd
    window = hub.client()  # the window's keys and API keys share one path in the app
    window.key("enter", True)
    assert wait_for(lambda: reports(runtime)[-1] == p.BUTTONS["cross"])
    assert "human has control" in text(await server.mcp.call_tool("press", {"button": "right"}))
    info = json.loads(text(await server.mcp.call_tool("status", {})))
    assert info["payload"]["human_has_control"]
    window.key("enter", False)
    assert wait_for(lambda: reports(runtime)[-1] == 0)
    assert wait_for(lambda: not hub.client().status()["pad"]["human_has_control"])
    assert "pressed" in text(await server.mcp.call_tool("press", {"button": "right", "hold_ms": 30}))
    window.key("w", True)
    assert wait_for(lambda: runtime.calls("pad_report")[-1]["ly"] == 0)
    window.close()  # the source vanishing must release what it held
    assert wait_for(lambda: runtime.calls("pad_report")[-1]["ly"] == 0x80)


async def test_two_servers_share_the_pad_without_busy(hub):
    other = server.Runtime()  # a second MCP session: its own connection and client id
    other.capture = server.runtime.capture
    try:
        hub.client("third").set(p.PadState(buttons=p.BUTTONS["l1"]))
        other.app().set(p.PadState(buttons=p.BUTTONS["r1"]))
        assert wait_for(lambda: reports(hub.padd)[-1] == p.BUTTONS["l1"] | p.BUTTONS["r1"])
        assert "pressed" in text(await server.mcp.call_tool("press", {"button": "cross", "hold_ms": 50}))
        assert (p.BUTTONS["l1"] | p.BUTTONS["r1"] | p.BUTTONS["cross"]) in reports(hub.padd)
    finally:
        other.stop()
    assert wait_for(lambda: reports(hub.padd)[-1] == p.BUTTONS["l1"])  # the closed session let go of R1


async def test_closing_the_server_leaves_the_app_and_pad_working(hub):
    assert "pressed" in text(await server.mcp.call_tool("press", {"button": "right", "hold_ms": 30}))
    server.runtime.stop()
    status = hub.client().status()
    assert status["pad"]["connected"] and hub.process.poll() is None
    keyboard = hub.client()
    keyboard.key("left", True)
    assert wait_for(lambda: reports(hub.padd)[-1] == p.BUTTONS["left"])
    keyboard.key("left", False)


async def test_tools_reconnect_after_the_app_restarts(hub):
    assert "pressed" in text(await server.mcp.call_tool("press", {"button": "right", "hold_ms": 30}))
    server.runtime.app().close()  # as if the app had gone away and come back
    assert "pressed" in text(await server.mcp.call_tool("press", {"button": "left", "hold_ms": 30}))


def test_title_reflects_link_state(hub):
    assert hub.client().status()["title"] == "PS5 MCP · pad connected"
    hub.padd.stop()
    assert wait_for(lambda: hub.client().status()["title"].startswith("PS5 MCP · no payload"))


async def test_record_and_play_back(hub):
    runtime, state = hub.padd, hub.root
    await server.mcp.call_tool("record_start", {})
    await server.mcp.call_tool("press", {"button": "triangle", "hold_ms": 50})
    saved = text(await server.mcp.call_tool("record_stop", {"name": "tri"}))
    assert "saved" in saved
    steps = json.loads((state / "recordings/tri.json").read_text())["steps"]
    assert steps[0]["buttons"] == ["triangle"] and 40 <= steps[0]["duration_ms"] <= 120
    before = len(runtime.calls("pad_report"))
    assert "played tri" in text(await server.mcp.call_tool("play_recording", {"name": "tri",
                                                                              "snapshot_after_ms": None}))
    assert p.BUTTONS["triangle"] in [c["buttons"] for c in runtime.calls("pad_report")[before:]]
    assert "not recording" in text(await server.mcp.call_tool("record_stop", {"name": "x"}))


async def test_wait_for_template(hub):
    import numpy as np
    from PIL import Image
    put_frame(hub.frame, Image.fromarray(np.random.default_rng(3).integers(0, 255, (1080, 1920), dtype=np.uint8)))
    await asyncio.sleep(0.3)
    assert "saved template" in text(await server.mcp.call_tool(
        "save_template", {"name": "spot", "x": 600, "y": 300, "width": 200, "height": 120}))
    found = text(await server.mcp.call_tool("wait_for", {"template": "spot", "timeout_ms": 1000}))
    assert "spot found at" in found
    put_frame(hub.frame, Image.fromarray(np.random.default_rng(4).integers(0, 255, (1080, 1920), dtype=np.uint8)))
    assert "spot gone" in text(await server.mcp.call_tool("wait_for", {"template": "spot", "gone": True,
                                                                       "timeout_ms": 1000}))
    assert "timeout" in text(await server.mcp.call_tool("wait_for", {"template": "spot", "timeout_ms": 300}))


async def test_claim_console_queues_a_second_session(hub):
    other = server.Runtime()  # a second MCP session
    other.capture = server.runtime.capture
    try:
        assert "is yours" in text(await server.mcp.call_tool("claim_console", {"reason": "testing menus"}))
        other.app().claim("waiting")
        with pytest.raises(server.ConsoleInUse):
            other.app().press(p.PadState(buttons=p.BUTTONS["cross"]), 30)
        info = json.loads(text(await server.mcp.call_tool("status", {})))
        assert info["claim"]["held_by_you"] and info["claim"]["queue"][0]["reason"] == "waiting"
        assert "released" in text(await server.mcp.call_tool("release_console", {}))
        assert other.app().lease()["granted"]
        busy = text(await server.mcp.call_tool("press", {"button": "right"}))
        assert busy.startswith("in use:") and "waiting" in busy
        queued = text(await server.mcp.call_tool("claim_console", {"reason": "again", "wait_s": 1}))
        assert "queued #1" in queued
        waiter = asyncio.create_task(server.mcp.call_tool("claim_console", {"reason": "again", "wait_s": 10}))
        await asyncio.sleep(0.3)
        await asyncio.to_thread(other.app().unclaim)
        assert "is yours" in text(await waiter)
        assert "pressed" in text(await server.mcp.call_tool("press", {"button": "right", "hold_ms": 30}))
    finally:
        other.stop()


async def test_looking_keeps_a_claim_alive(hub):
    await server.mcp.call_tool("claim_console", {"reason": "watching", "idle_timeout_s": 10})
    await asyncio.sleep(3)
    await server.mcp.call_tool("snapshot", {"max_width": 320})
    info = json.loads(text(await server.mcp.call_tool("status", {})))
    assert info["claim"]["owner"]["expires_in_s"] >= 9
