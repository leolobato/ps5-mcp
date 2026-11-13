"""Offline Linux service and MCP integration, using a local recording padd stub."""
from __future__ import annotations

import json
import socket
import threading
import time

import pytest
from PIL import Image

from ps5mcp import backends, capture, cli, server
from ps5mcp.client import ConsoleInUse, PadController
from ps5mcp.hub import AppClient, AppError
from ps5mcp.linux.backend import LinuxHub
from ps5mcp.linux.hub import Hub, serve
from ps5mcp.protocol import BUTTONS, PadState

from .test_padd_host import BINARY, Padd, wait_for


@pytest.fixture(autouse=True)
def offline(monkeypatch):
    monkeypatch.delenv("PS5MCP_ALLOW_CONSOLE", raising=False)
    monkeypatch.delenv("PS5_HOST", raising=False)
    monkeypatch.setenv("PS5MCP_BACKEND", "linux")


@pytest.fixture
def hub(tmp_path):
    service = Hub(tmp_path)
    ready = threading.Event()
    thread = threading.Thread(target=serve, args=(service, ready))
    thread.start()
    assert ready.wait(3)
    yield service
    service.server.shutdown()
    thread.join(5)
    assert not thread.is_alive()
    assert not (tmp_path / "capture.sock").exists()


def connect(hub, name="test"):
    return AppClient(hub.root / "capture.sock", client=name)


def test_backend_selection(tmp_path, monkeypatch):
    monkeypatch.delenv("PS5MCP_BACKEND")
    monkeypatch.setattr(backends.sys, "platform", "linux")
    assert isinstance(backends.select(tmp_path), LinuxHub)
    monkeypatch.setattr(backends.sys, "platform", "darwin")
    assert type(backends.select(tmp_path)) is capture.NativeApp
    monkeypatch.setenv("PS5MCP_BACKEND", "linux")
    assert isinstance(capture.backend(tmp_path), LinuxHub)
    with pytest.raises(capture.CaptureError, match="Unsupported"):
        backends.select(tmp_path, "unknown")


def test_socket_status_synthetic_and_unsupported(hub):
    client = connect(hub)
    try:
        assert client.status()["source"] == "synthetic"
        assert not client.status()["pad"]["connected"]
        assert client.call("snapshot")["path"] == str(hub.latest)
        with Image.open(hub.latest) as image:
            assert image.size == (1280, 720)
        for cmd in ("frame_meter", "watch_change", "rp_text", "padd_start"):
            with pytest.raises(AppError, match="does not support"):
                client.call(cmd)
        with pytest.raises(AppError, match="offline"):
            client.press(PadState(buttons=1), 10)
    finally:
        client.close()


def test_claim_contention_disconnect_and_queue(hub):
    a, b, c = [connect(hub, name) for name in ("a", "b", "c")]
    try:
        assert a.claim("first")["granted"]
        assert b.claim("second")["position"] == 1
        assert c.claim("third")["position"] == 2
        with pytest.raises(ConsoleInUse):
            b.set(PadState(buttons=1))
        assert a.unclaim()["released"]
        assert b.lease()["granted"]
        b.close()
        assert wait_for(lambda: c.lease()["granted"])
        a.close()
        assert wait_for(lambda: c.status()["clients"] == 1)
        assert c.unclaim()["released"]
    finally:
        for client in (a, b, c):
            client.close()


def test_claim_expiration_and_refresh(hub):
    a, b = connect(hub), connect(hub)
    try:
        a.claim("expiring", 10)
        b.claim("queued")
        with hub.lock:
            hub.sessions[hub.owner]["t"] -= 11
        assert b.lease()["granted"]
        assert b.lease()["owner"]["expires_in_s"] > 9
        with pytest.raises(AppError, match="idle_s"):
            a.claim("bad", float("nan"))
    finally:
        a.close()
        b.close()


def test_capture_failure_and_recovery(hub):
    backend = LinuxHub(hub.root)
    with hub.lock:
        hub.video = "file:/does/not/exist.png"
    with pytest.raises(capture.CaptureError):
        backend.refresh()
    assert backend.status()["source"] == "unavailable"
    with hub.lock:
        hub.video = "synthetic"
    backend.refresh()
    assert backend.frame_age() < 1


def test_malformed_request_does_not_kill_hub(hub):
    with socket.socket(socket.AF_UNIX) as conn:
        conn.connect(str(hub.root / "capture.sock"))
        conn.sendall(b'[]\ninvalid\n{"id":3,"cmd":"status"}\n')
        lines = conn.makefile("rb")
        assert not json.loads(lines.readline())["ok"]
        assert not json.loads(lines.readline())["ok"]
        assert json.loads(lines.readline())["id"] == 3


async def test_mcp_lifecycle_snapshot_and_offline_guards(tmp_path, monkeypatch):
    monkeypatch.setenv("PS5MCP_STATE", str(tmp_path))
    monkeypatch.setenv("PS5_HOST", "192.0.2.123")  # must never authorize access
    monkeypatch.setattr(server, "runtime", server.Runtime())
    runtime = server.runtime
    try:
        async with server.lifespan(server.mcp):
            assert isinstance(runtime.capture, LinuxHub)
            result = await server.mcp.call_tool("snapshot", {"max_width": 320})
            assert result.content[0].type == "image"
            assert "is yours" in (await server.mcp.call_tool("claim_console", {"reason": "MCP test"})).content[0].text
            other = AppClient(tmp_path / "capture.sock", client="other")
            try:
                other.claim("next")
                assert "now held by" in (await server.mcp.call_tool("release_console", {})).content[0].text
                assert "queued #1" in (await server.mcp.call_tool("claim_console", {"reason": "queued"})).content[0].text
            finally:
                other.close()
            result = await server.mcp.call_tool("status", {})
            assert "LinuxHub" in result.content[0].text
            for tool, arguments in (("list_apps", {}), ("install", {"path": "missing.pkg"}),
                                    ("push", {"local_path": "x", "remote_path": "/x"}),
                                    ("pull", {"remote_path": "/x", "local_path": "x"})):
                result = await server.mcp.call_tool(tool, arguments)
                assert "offline mode" in result.content[0].text
        assert runtime._app.closed
        # MCP shutdown leaves the shared hub alive.
        assert runtime.capture.pid() is not None
    finally:
        runtime.stop()
        LinuxHub(tmp_path).stop()


def test_cli_offline_and_capture(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("PS5MCP_STATE", str(tmp_path))
    assert cli.main(["pad", "press", "cross"]) == 1
    assert "disabled" in capsys.readouterr().err
    try:
        assert cli.main(["capture", "start", "--backend", "linux", "--video", "synthetic"]) == 0
        assert cli.main(["capture", "status"]) == 0
        assert cli.main(["capture", "start", "--backend", "ffmpeg"]) == 1
        assert cli.main(["view"]) == 0
        assert cli.main(["capture", "stop"]) == 0
    finally:
        LinuxHub(tmp_path).stop()


@pytest.mark.skipif(not BINARY.exists(), reason="make build/padd-host")
def test_controller_input_disconnect_reconnect_and_cleanup(hub, tmp_path):
    (tmp_path / "padd").mkdir()
    padd = Padd(tmp_path / "padd")
    controller = PadController("127.0.0.1", padd.port, ack_timeout=.75,
                               on_ready=hub.reset_input, on_disconnect=hub.reset_input)
    hub.controller = controller
    a, b = connect(hub), connect(hub)
    try:
        assert wait_for(lambda: controller.status().connected)
        a.set(PadState(buttons=BUTTONS["cross"]))
        assert wait_for(lambda: padd.last_buttons() == BUTTONS["cross"])
        with pytest.raises(ConsoleInUse):
            b.set(PadState(buttons=BUTTONS["right"]))
        a.release()
        b.set(PadState(buttons=BUTTONS["right"]))
        b.close()
        assert wait_for(lambda: padd.last_buttons() == 0)
        a.release()
        assert wait_for(lambda: padd.last_buttons() == 0)
        a.press(PadState(buttons=BUTTONS["triangle"]), 50)
        assert wait_for(lambda: padd.last_buttons() == 0)
        assert BUTTONS["triangle"] in [c["buttons"] for c in padd.calls("pad_report")]
        # Claim handoff cancels previously held state.
        a.set(PadState(buttons=1))
        b = connect(hub)
        b.claim("exclusive")
        assert wait_for(lambda: padd.last_buttons() == 0)
        b.unclaim()
        controller.link().close()
        assert wait_for(lambda: controller.reconnects >= 1 and controller.status().connected)
        assert wait_for(lambda: padd.last_buttons() == 0)
        a.press(PadState(buttons=BUTTONS["circle"]), 30, wait=2)
        # EOF during a long press releases input immediately.
        raw = socket.socket(socket.AF_UNIX)
        raw.connect(str(hub.root / "capture.sock"))
        raw.sendall(b'{"cmd":"press","state":{"buttons":1},"hold_ms":3000}\n')
        assert wait_for(lambda: padd.last_buttons() == 1)
        start = time.monotonic()
        raw.close()
        assert wait_for(lambda: padd.last_buttons() == 0)
        assert time.monotonic() - start < 1
        padd.stop()
        assert wait_for(lambda: not controller.status().connected)
    finally:
        a.close()
        b.close()
        controller.close()
        hub.controller = None
        padd.stop()


def test_file_capture(hub, tmp_path):
    source = tmp_path / "source.png"
    Image.new("RGB", (64, 48), "red").save(source)
    with hub.lock:
        hub.video = f"file:{source}"
    LinuxHub(hub.root).refresh()
    with Image.open(hub.latest) as image:
        assert image.size == (64, 48)
        assert image.getpixel((0, 0))[0] > 240


def test_host_does_not_enable_connections(tmp_path, monkeypatch):
    def forbidden(*args, **kwargs):
        pytest.fail("Offline hub tried to connect to a console")
    monkeypatch.setattr(socket, "create_connection", forbidden)
    service = Hub(tmp_path, host="192.0.2.123")
    assert service.controller is None


async def test_mcp_over_stdio(tmp_path, monkeypatch):
    import os
    import sys

    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    monkeypatch.setenv("PS5MCP_STATE", str(tmp_path))
    params = StdioServerParameters(command=sys.executable, args=["-m", "ps5mcp.server"], env={
        **os.environ, "PS5MCP_VIDEO": "synthetic", "PS5MCP_ALLOW_CONSOLE": "0"})
    backend = LinuxHub(tmp_path)
    try:
        async with (
            stdio_client(params) as (read, write),
            ClientSession(read, write, read_timeout_seconds=10) as session,
        ):
            await session.initialize()
            tools = await session.list_tools()
            assert "snapshot" in [tool.name for tool in tools.tools]
            result = await session.call_tool("snapshot", {"max_width": 320})
            assert result.content[0].type == "image"
        assert backend.pid() is not None
        assert wait_for(lambda: backend.status()["clients"] == 1)  # status request itself
    finally:
        backend.stop()


def test_backend_reconnect_after_service_restart(tmp_path):
    backend = LinuxHub(tmp_path)
    try:
        capture.snapshot(tmp_path / "offline.jpg", daemon=backend)
        first = backend.pid()
        client = AppClient(backend.socket)
        assert client.status()["pid"] == first
        assert backend.start() == first  # start is idempotent
        backend.stop()
        assert wait_for(lambda: client.closed)
        second = backend.start()
        assert second != first
        client.close()
        client = AppClient(backend.socket)
        assert client.status()["pid"] == second
        client.close()
    finally:
        backend.stop()
