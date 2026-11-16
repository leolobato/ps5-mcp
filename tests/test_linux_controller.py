"""Controller safety over localhost-only padd protocol fixtures; no PS5 access."""
from __future__ import annotations

import asyncio
import contextlib
import socket
import socketserver
import struct
import threading
import time

import pytest

from ps5mcp import protocol as p
from ps5mcp import server
from ps5mcp.capture import CaptureError
from ps5mcp.client import ConsoleInUse, PadError, PadLink
from ps5mcp.hub import AppError
from ps5mcp.linux.backend import LinuxHub
from ps5mcp.linux.controller import ConnectionConfig, LinuxAppClient, config_from_environment
from ps5mcp.linux.hub import Hub, serve


def wait(predicate, seconds=4):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(.01)
    return False


class FakePadd:
    """Wire-level fixture supporting fault injection and virtual controller commands."""
    def __init__(self):
        self.states = []
        self.commands = []
        self.sockets = set()
        self.counter = 0
        self.suppress_acks = False
        self.suppress_commands = False
        self.command_reply_delay = 0
        self.suppress_ping = False
        self.bad_hello = False
        self.active = 1
        self.handles = [1000, -1, -1, -1]
        self.users = [11, -1, -1, -1]
        fake = self
        self.flags = p.FLAG_PAD_READY | p.FLAG_USERS | p.FLAG_PADS | p.FLAG_USER_NAME | p.FLAG_UNINSTALL

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                fake.counter += 1
                generation = fake.counter
                fake.sockets.add(self.request)
                self.request.settimeout(.1)
                def send(kind, payload):
                    self.request.sendall(p.encode(kind, payload))
                try:
                    if fake.bad_hello:
                        send(p.Type.HELLO, b"bad")
                        return
                    send(p.Type.HELLO, p._HELLO.pack(1, 0x10A, 1000, 11, fake.flags, 0))
                    reader = p.Reader()
                    while True:
                        try:
                            data = self.request.recv(4096)
                        except TimeoutError:
                            continue
                        if not data:
                            return
                        for kind, payload in reader.feed(data):
                            if kind == p.Type.STATE:
                                seq, state = p.decode_state(payload)
                                fake.states.append((generation, state))
                                if not fake.suppress_acks:
                                    send(p.Type.ACK, p._ACK.pack(seq, 0))
                            elif kind == p.Type.PING and not fake.suppress_ping:
                                token = struct.unpack("<I", payload)[0]
                                send(p.Type.PING, p._PONG.pack(token, 1, 0x10A, 100, 1000, fake.flags, 0, 0, 0))
                            elif kind == p.Type.GET_STATE:
                                state = fake.states[-1][1] if fake.states else p.PadState()
                                self.request.sendall(p.encode_state(0, state))
                            elif kind == p.Type.GET_USERS:
                                payload = struct.pack("<ii", 0, 11)
                                for i in range(p.LOGIN_USERS):
                                    payload += p._LOGIN_USER.pack(11 + i, f"User{i}".encode())
                                send(kind, payload)
                            elif kind == p.Type.GET_PADS:
                                send(kind, struct.pack("<B3x", fake.active) + b"".join(
                                    struct.pack("<ii", h, u) for h, u in zip(fake.handles, fake.users)))
                            elif kind == p.Type.COMMAND:
                                seq, op, raw = p._COMMAND.unpack(payload)
                                arg = raw.split(b"\0")[0].decode()
                                fake.commands.append((op, arg))
                                if fake.suppress_commands:
                                    continue
                                if fake.command_reply_delay:
                                    time.sleep(fake.command_reply_delay)
                                status = 0
                                if op == p.Command.PAD:
                                    words = arg.split()
                                    if words[0] == "connect":
                                        index = next((i for i, h in enumerate(fake.handles) if h < 0), None)
                                        if index is None:
                                            status = 28
                                        else:
                                            fake.handles[index] = 1000 + index
                                            fake.users[index] = int(words[1]) if len(words) > 1 else 11 + index
                                    else:
                                        index = int(words[1]) - 1 if len(words) > 1 else max(
                                            i for i, h in enumerate(fake.handles) if h >= 0)
                                        fake.handles[index] = fake.users[index] = -1
                                        fake.active = 1
                                elif op == p.Command.SELECT_PAD:
                                    if fake.handles[int(arg) - 1] < 0:
                                        status = 2
                                    else:
                                        fake.active = int(arg)
                                send(p.Type.ACK, p._ACK.pack(seq, status))
                except (OSError, p.ProtocolError):
                    pass
                finally:
                    fake.sockets.discard(self.request)

        class Server(socketserver.ThreadingTCPServer):
            daemon_threads = True
            allow_reuse_address = True
        self.server = Server(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": .02}, daemon=True)
        self.thread.start()

    def drop(self):
        for connection in list(self.sockets):
            with contextlib.suppress(OSError):
                connection.shutdown(socket.SHUT_RDWR)
                connection.close()

    def close(self):
        self.drop()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


@pytest.fixture(autouse=True)
def isolated(monkeypatch):
    monkeypatch.setenv("PS5MCP_ALLOW_CONSOLE", "0")
    monkeypatch.setenv("PS5MCP_BACKEND", "linux")
    monkeypatch.setenv("PS5MCP_VIDEO", "synthetic")
    for name in ("PS5_HOST", "PS5MCP_PAD_PORT", "PS5MCP_STREAM_PORT", "PS5MCP_VIEW"):
        monkeypatch.delenv(name, raising=False)


@pytest.fixture
def fake():
    fixture = FakePadd()
    yield fixture
    fixture.close()


@pytest.fixture
def hub(fake, tmp_path, monkeypatch):
    monkeypatch.setenv("PS5MCP_ALLOW_CONSOLE", "1")
    monkeypatch.setenv("PS5_HOST", "127.0.0.1")
    monkeypatch.setenv("PS5MCP_PAD_PORT", str(fake.port))
    service = Hub(tmp_path, host="127.0.0.1", port=fake.port)
    ready = threading.Event()
    thread = threading.Thread(target=serve, args=(service, ready), daemon=True)
    thread.start()
    assert ready.wait(3)
    assert wait(lambda: service.controller.status().connected)
    assert wait(lambda: service.controller.cached()[0] is not None)
    service.controller.command_timeout = .15
    yield service
    service.server.shutdown()
    thread.join(5)
    assert not thread.is_alive()
    assert not service.controller._thread.is_alive()


def connect(hub):
    return LinuxAppClient(hub.root / "capture.sock")


def test_opt_in_and_configuration_are_explicit(tmp_path, monkeypatch):
    def forbidden(*args, **kwargs):
        pytest.fail("Offline configuration must not create console sockets")
    monkeypatch.setattr(socket, "create_connection", forbidden)
    monkeypatch.setenv("PS5_HOST", "192.0.2.123")
    service = Hub(tmp_path)
    assert service.controller is None
    assert config_from_environment().port == 9305
    monkeypatch.setenv("PS5MCP_ALLOW_CONSOLE", "1")
    monkeypatch.delenv("PS5_HOST")
    with pytest.raises(ValueError, match="explicit"):
        config_from_environment()
    with pytest.raises(ValueError, match="1..65535"):
        ConnectionConfig("127.0.0.1", 0, True).validate()
    with pytest.raises(ValueError):
        ConnectionConfig(" ", 9305, True).validate()


def test_read_only_status_and_ping_while_claimed(hub, fake):
    a, b = connect(hub), connect(hub)
    try:
        a.claim("owner")
        status = b.status()
        assert status["pad"]["host"] == "127.0.0.1" and status["pad"]["port"] == fake.port
        assert status["pad"]["version"] == "1.10"
        assert status["controllers"]["active"] == 1
        assert status["login_users"]["users"][0]["user_id"] == 11
        before = hub.controller.revision
        assert b.call("state")["state"]["buttons"] == 0
        assert hub.controller.revision == before
        assert b.ping()["protocol"] == 1
        assert fake.commands == []
    finally:
        a.close()
        b.close()


def test_unclaimed_conflicting_input_is_refused(hub, fake):
    a, b = connect(hub), connect(hub)
    try:
        a.set(p.PadState(buttons=p.BUTTONS["cross"], lx=0))
        with pytest.raises(ConsoleInUse):
            b.set(p.PadState(buttons=p.BUTTONS["circle"], lx=255))
        assert fake.states[-1][1].lx == 0
        a.release()
        b.press(p.PadState(l2=255), 20)
        assert fake.states[-1][1].is_neutral()
    finally:
        a.close()
        b.close()


def test_fifo_claims_expire_and_neutralise(hub, fake):
    a, b, c = connect(hub), connect(hub), connect(hub)
    try:
        a.claim("a")
        a.set(p.PadState(buttons=1))
        assert b.claim("b")["position"] == 1
        assert c.claim("c")["position"] == 2
        with hub.lock:
            hub.sessions[hub.owner]["t"] -= 601
        assert b.lease()["granted"]
        assert wait(lambda: fake.states[-1][1].is_neutral())
        b.close()
        assert wait(lambda: c.lease()["granted"])
        with pytest.raises(ConsoleInUse):
            a.press(p.PadState(buttons=1), 20)
    finally:
        a.close()
        b.close()
        c.close()


def test_local_timeout_closes_session_and_cancels_hold(hub, fake):
    client = connect(hub)
    with pytest.raises(AppError, match="timed out"):
        client.call("press", state={"buttons": 1}, hold_ms=5000, timeout=.1)
    assert client.closed
    assert wait(lambda: fake.states[-1][1].is_neutral(), 1)
    assert wait(lambda: not hub.sessions)


def test_emergency_release_interrupts_hold_without_waiting(hub, fake):
    client = connect(hub)
    errors = []
    def hold():
        try:
            client.press(p.PadState(buttons=1), 5000)
        except AppError as exc:
            errors.append(exc)
    worker = threading.Thread(target=hold)
    worker.start()
    assert wait(lambda: fake.states[-1][1].buttons == 1)
    began = time.monotonic()
    client.release_all()
    worker.join(1)
    assert not worker.is_alive() and errors
    assert time.monotonic() - began < 1
    assert wait(lambda: fake.states[-1][1].is_neutral())
    client.close()


def test_transport_drop_cancels_input_and_does_not_replay(hub, fake):
    client = connect(hub)
    client.set(p.PadState(buttons=1, ry=0))
    generation = fake.counter
    fake.drop()
    assert wait(lambda: fake.counter > generation and hub.controller.status().connected)
    assert wait(lambda: not hub.sessions or all(s["state"].is_neutral() for s in hub.sessions.values()))
    assert all(state.is_neutral() for gen, state in fake.states if gen > generation)
    client.press(p.PadState(buttons=2), 20)
    assert fake.states[-1][1].is_neutral()
    client.close()


def test_ack_timeout_releases_and_recovers(hub, fake):
    client = connect(hub)
    fake.suppress_acks = True
    with pytest.raises(AppError):
        client.set(p.PadState(buttons=1))
    assert wait(lambda: hub.controller.current().is_neutral())
    fake.suppress_acks = False
    assert wait(lambda: hub.controller.status().connected)
    client.press(p.PadState(buttons=2), 20)
    assert fake.states[-1][1].is_neutral()
    client.close()


def test_command_timeout_sends_neutral_and_does_not_replay(hub, fake):
    client = connect(hub)
    client.set(p.PadState(buttons=1))
    fake.suppress_commands = True
    with pytest.raises(AppError, match="timed out"):
        client.command("launch", "FAKE00001")
    assert wait(lambda: hub.controller.current().is_neutral())
    assert len(fake.commands) == 1
    assert fake.states[-1][1].is_neutral()
    fake.suppress_commands = False
    assert wait(lambda: hub.controller.status().connected)
    assert len(fake.commands) == 1
    client.close()


def test_virtual_controller_connect_select_disconnect(hub, fake):
    client = connect(hub)
    try:
        assert client.command("pad", "connect 12") == 0
        assert client.status()["controllers"]["active"] == 2
        assert "no automatic buttons" in client.status()["notice"]
        assert client.command("select_pad", "1") == 0
        assert client.command("pad", "disconnect 2") == 0
        assert len(client.status()["controllers"]["list"]) == 1
        for op in ("padd_start", "shutdown"):
            with pytest.raises(AppError, match="Unsupported"):
                client.command(op)
    finally:
        client.close()


@pytest.mark.parametrize("capture_error", [None, "Capture frame is stale; waiting for device recovery"])
def test_capture_status_preserves_controller_assignment_notice(hub, monkeypatch, capture_error):
    from types import SimpleNamespace

    client = connect(hub)
    try:
        assert client.command("pad", "connect 12") == 0
        notice = client.status()["notice"]
        assert "no automatic buttons" in notice
        capture = SimpleNamespace(
            config=SimpleNamespace(source="/dev/video99", input_format="mjpeg", size="1920x1080", fps="60"),
            info=lambda: {"capture_error": capture_error, "frame_sequence": 1},
        )
        with monkeypatch.context() as patch:
            patch.setattr(hub, "video_capture", capture)
            status = client.status()
            assert status["notice"] == (capture_error or notice)
            assert status["capture_error"] == capture_error
    finally:
        client.close()


async def test_existing_mcp_input_tools_and_cancelled_sequences(hub, fake, monkeypatch):
    monkeypatch.setenv("PS5MCP_STATE", str(hub.root))
    monkeypatch.setattr(server, "HOST", "127.0.0.1")
    monkeypatch.setattr(server, "runtime", server.Runtime())
    server.runtime.start()
    try:
        for tool, arguments in (("press", {"button": "cross", "hold_ms": 20}),
                               ("hold", {"buttons": ["l1", "r1"], "duration_ms": 20}),
                               ("stick", {"side": "left", "x": -1, "y": 1, "duration_ms": 20}),
                               ("trigger", {"side": "right", "value": .7, "duration_ms": 20}),
                               ("touchpad", {"duration_ms": 20}),
                               ("ps_button", {"hold_ms": 20, "snapshot_after_ms": None}),
                               ("sequence", {"steps": [{"buttons": ["cross"], "duration_ms": 20},
                                                       {"rx": 1, "duration_ms": 20}]})):
            result = await server.mcp.call_tool(tool, arguments)
            assert not result.content[0].text.startswith("error:"), result
            assert wait(lambda: fake.states[-1][1].is_neutral())
        assert any(state.lx == 0 and state.ly == 255 for _, state in fake.states)
        assert any(state.r2 > 0 for _, state in fake.states)
        assert any(state.touch[0].active for _, state in fake.states)
        task = asyncio.create_task(server.sequence([{"buttons": ["cross"], "duration_ms": 5000}]))
        assert await asyncio.to_thread(wait, lambda: fake.states[-1][1].buttons == p.BUTTONS["cross"])
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert await asyncio.to_thread(wait, lambda: fake.states[-1][1].is_neutral())
        task = asyncio.create_task(server.press("cross", hold_ms=5000))
        assert await asyncio.to_thread(wait, lambda: fake.states[-1][1].buttons == p.BUTTONS["cross"])
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert await asyncio.to_thread(wait, lambda: fake.states[-1][1].is_neutral())
    finally:
        server.runtime.stop()


def test_offline_client_cannot_send_input_to_enabled_hub(hub, monkeypatch):
    monkeypatch.setenv("PS5MCP_ALLOW_CONSOLE", "0")
    client = connect(hub)
    try:
        assert client.status()["pad"]["connected"]
        with pytest.raises(PadError, match="offline"):
            client.press(p.PadState(buttons=1), 20)
    finally:
        client.close()


def test_malformed_hello_closes_socket_and_controller_can_retry(fake):
    fake.bad_hello = True
    with pytest.raises(PadError, match="HELLO"):
        PadLink("127.0.0.1", fake.port, timeout=.1)
    assert wait(lambda: not fake.sockets)
    fake.bad_hello = False
    link = PadLink("127.0.0.1", fake.port)
    link.close()


async def test_sequence_does_not_resume_after_reconnect(hub, fake, monkeypatch):
    monkeypatch.setenv("PS5MCP_STATE", str(hub.root))
    monkeypatch.setattr(server, "HOST", "127.0.0.1")
    monkeypatch.setattr(server, "runtime", server.Runtime())
    server.runtime.start()
    try:
        task = asyncio.create_task(server.sequence([
            {"buttons": ["cross"], "duration_ms": 1200},
            {"buttons": ["circle"], "duration_ms": 20}]))
        assert await asyncio.to_thread(wait, lambda: fake.states[-1][1].buttons == p.BUTTONS["cross"])
        generation = fake.counter
        fake.drop()
        assert await asyncio.to_thread(wait, lambda: fake.counter > generation and hub.controller.status().connected)
        result = await task
        assert result.startswith("error:") and "interrupted" in result
        assert not any(state.buttons == p.BUTTONS["circle"] for gen, state in fake.states if gen > generation)
    finally:
        server.runtime.stop()


def test_set_input_watchdog_expires_without_keepalive(hub, fake):
    client = connect(hub)
    try:
        client.set(p.PadState(lx=0, l2=255))
        with hub.lock:
            hub.sessions[hub.input_owner]["input_deadline"] = time.monotonic() - 1
        assert wait(lambda: fake.states[-1][1].is_neutral())
        assert hub.input_owner is None
    finally:
        client.close()


def test_hold_interrupted_by_disconnect(hub, fake):
    client = connect(hub)
    errors = []
    def hold():
        try:
            client.press(p.PadState(buttons=1), 5000)
        except AppError as exc:
            errors.append(exc)
    worker = threading.Thread(target=hold)
    worker.start()
    assert wait(lambda: fake.states[-1][1].buttons == 1)
    fake.drop()
    worker.join(1)
    assert not worker.is_alive() and errors
    assert wait(lambda: hub.controller.status().connected)
    assert hub.controller.current().is_neutral()
    client.close()


def test_status_stays_responsive_during_command_timeout(hub, fake):
    a, b = connect(hub), connect(hub)
    fake.suppress_commands = True
    hub.controller.command_timeout = .5
    errors = []
    def command():
        try:
            a.command("launch", "FAKE00001")
        except AppError as exc:
            errors.append(exc)
    worker = threading.Thread(target=command)
    worker.start()
    assert wait(lambda: fake.commands)
    began = time.monotonic()
    assert b.status()["pad"]["connected"]
    assert time.monotonic() - began < .2
    with pytest.raises(ConsoleInUse):
        b.press(p.PadState(buttons=2), 20)
    worker.join(2)
    assert errors and not worker.is_alive()
    a.close()
    b.close()


def test_running_hub_rejects_different_endpoint(hub, monkeypatch):
    monkeypatch.setenv("PS5MCP_STATE", str(hub.root))
    monkeypatch.setenv("PS5_HOST", "192.0.2.123")
    # Validation must fail before attempting to create any socket to this address.
    def forbidden(*args, **kwargs):
        pytest.fail("An endpoint mismatch must never start a new hub")
    monkeypatch.setattr("subprocess.Popen", forbidden)
    with pytest.raises(CaptureError, match="different padd endpoint"):
        LinuxHub(hub.root).start()


def test_queued_press_is_cancelled_by_emergency_release(hub, fake):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.connect(str(hub.root / "capture.sock"))
        connection.sendall(b'{"id":1,"cmd":"press","state":{"buttons":1},"hold_ms":3000}\n')
        assert wait(lambda: fake.states[-1][1].buttons == 1)
        connection.sendall(b'{"id":2,"cmd":"press","state":{"buttons":2},"hold_ms":20}\n'
                           b'{"id":3,"cmd":"release_all"}\n')
        assert wait(lambda: fake.states[-1][1].is_neutral())
        time.sleep(.15)
        assert not any(state.buttons == 2 for _, state in fake.states)


def test_active_input_released_before_shutdown_completes(fake, tmp_path, monkeypatch):
    monkeypatch.setenv("PS5MCP_ALLOW_CONSOLE", "1")
    monkeypatch.setenv("PS5_HOST", "127.0.0.1")
    service = Hub(tmp_path, host="127.0.0.1", port=fake.port)
    ready = threading.Event()
    thread = threading.Thread(target=serve, args=(service, ready), daemon=True)
    thread.start()
    assert ready.wait(3)
    client = LinuxAppClient(tmp_path / "capture.sock")
    try:
        assert wait(lambda: service.controller.status().connected)
        client.set(p.PadState(buttons=1), wait=2)
        service.server.shutdown()
        thread.join(3)
        assert not thread.is_alive()
        assert fake.states[-1][1].is_neutral()
        assert not service.controller._thread.is_alive()
    finally:
        client.close()
        if thread.is_alive():
            service.server.shutdown()
            thread.join(3)


async def test_mcp_controller_management_and_console_command_mapping(hub, fake, monkeypatch):
    monkeypatch.setenv("PS5MCP_STATE", str(hub.root))
    monkeypatch.setattr(server, "HOST", "127.0.0.1")
    monkeypatch.setattr(server, "runtime", server.Runtime())
    server.runtime.start()
    try:
        actions = (("connect_controller", {"user_id": 12, "snapshot_after_ms": None}),
                   ("use_controller", {"controller": 1}),
                   ("disconnect_controller", {"controller": 2, "snapshot_after_ms": None}),
                   ("home", {"snapshot_after_ms": None}),
                   ("close_app", {"snapshot_after_ms": None}),
                   ("launch", {"title_id": "FAKE00001", "snapshot_after_ms": None}))
        for tool, arguments in actions:
            result = await server.mcp.call_tool(tool, arguments)
            assert not result.content[0].text.startswith("error:"), result
        assert (p.Command.HOME, "suspend") in fake.commands
        assert (p.Command.CLOSE, "") in fake.commands
        assert (p.Command.LAUNCH, "FAKE00001") in fake.commands
        assert all(op != p.Command.UNINSTALL for op, _ in fake.commands)
    finally:
        server.runtime.stop()


def test_same_button_handoff_has_acknowledged_neutral_gap(hub, fake):
    a, b = connect(hub), connect(hub)
    try:
        a.set(p.PadState(buttons=1))
        start = len(fake.states)
        b.claim("take control")
        b.press(p.PadState(buttons=1), 20)
        states = [state for _, state in fake.states[start:]]
        pressed = next(i for i, state in enumerate(states) if state.buttons == 1)
        assert any(state.is_neutral() for state in states[:pressed])
        assert states[-1].is_neutral()
    finally:
        a.close()
        b.close()


def test_disconnected_session_does_not_select_after_delayed_pad_connect(hub, fake):
    hub.controller.command_timeout = .5
    fake.command_reply_delay = .15
    client = connect(hub)
    errors = []
    def command():
        try:
            client.command("pad", "connect 12")
        except AppError as exc:
            errors.append(exc)
    worker = threading.Thread(target=command)
    worker.start()
    assert wait(lambda: (p.Command.PAD, "connect 12") in fake.commands)
    client.close()
    worker.join(2)
    assert not worker.is_alive() and errors
    assert wait(lambda: fake.handles[1] >= 0)
    assert not any(op == p.Command.SELECT_PAD for op, _ in fake.commands)
    assert wait(lambda: hub.controller.current().is_neutral())


async def test_mcp_status_uses_cache_during_pending_command(hub, fake, monkeypatch):
    monkeypatch.setenv("PS5MCP_STATE", str(hub.root))
    monkeypatch.setattr(server, "HOST", "127.0.0.1")
    monkeypatch.setattr(server, "runtime", server.Runtime())
    server.runtime.start()
    client = connect(hub)
    fake.suppress_commands = True
    hub.controller.command_timeout = .5
    errors = []
    def command():
        try:
            client.command("launch", "FAKE00001")
        except AppError as exc:
            errors.append(exc)
    worker = threading.Thread(target=command)
    worker.start()
    try:
        assert await asyncio.to_thread(wait, lambda: fake.commands)
        began = time.monotonic()
        info = await asyncio.wait_for(server.status(), timeout=.3)
        assert info["payload"]["connected"]
        assert time.monotonic() - began < .3
    finally:
        await asyncio.to_thread(worker.join, 2)
        client.close()
        server.runtime.stop()
    assert errors


def test_public_verification_requires_claim_and_neutral(hub, fake):
    a, b = connect(hub), connect(hub)
    try:
        with pytest.raises(ConsoleInUse):
            a.call('controller_verify')
        assert a.claim('verify')['granted']
        result = a.call('controller_verify', wait=1)
        assert result['neutral'] and result['hello']['protocol'] == 1
        with pytest.raises(ConsoleInUse):
            b.call('controller_verify')
        a.release_all()
        assert a.call('controller_verify')['neutral']
        assert fake.commands == []
    finally:
        a.close()
        b.close()


def test_guarded_press_requires_explicit_claim(hub):
    a = connect(hub)
    try:
        with pytest.raises(ConsoleInUse):
            a.call('press', state={'buttons': 1}, hold_ms=20, require_claim=True)
        a.claim('guarded')
        a.call('press', state={'buttons': 1}, hold_ms=20, require_claim=True)
        assert a.call('controller_verify')['neutral']
    finally:
        a.close()


def test_cli_ready_reports_non_neutral_as_failure(monkeypatch):
    from types import SimpleNamespace

    from ps5mcp import cli
    calls = []
    async def claim(*args, **kwargs):
        return 'claimed'
    async def ready(*args, **kwargs):
        return {'neutral': False}
    monkeypatch.setattr(server, 'runtime', SimpleNamespace(start=lambda: calls.append('start'),
                                                          stop=lambda: calls.append('stop')))
    monkeypatch.setattr(server, 'claim_console', claim)
    monkeypatch.setattr(server, 'controller_ready', ready)
    assert cli.main(['controller', 'ready']) == 1
    assert calls == ['start', 'stop']


async def test_public_guarded_press_and_cancellation(hub, fake, monkeypatch):
    monkeypatch.setenv('PS5MCP_STATE', str(hub.root))
    monkeypatch.setattr(server, 'runtime', server.Runtime())
    server.runtime.start()
    try:
        refused = await server.press('right', require_claim=True)
        assert refused.startswith('in use:')
        await server.claim_console('guarded MCP regression')
        await server.press('right', hold_ms=20, require_claim=True)
        assert (await server.controller_ready())['neutral']
        task = asyncio.create_task(server.press('left', hold_ms=1000, require_claim=True))
        assert await asyncio.to_thread(wait, lambda: fake.states[-1][1].buttons == p.BUTTONS['left'])
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert await asyncio.to_thread(wait, lambda: fake.states[-1][1].is_neutral())
    finally:
        server.runtime.stop()


def test_wire_verification_timeout_recovers_without_input_replay(hub, fake, monkeypatch):
    a = connect(hub)
    try:
        a.claim('wire timeout')
        link = hub.controller.link()
        def timeout(*args, **kwargs):
            raise PadError('wire state timeout')
        monkeypatch.setattr(link, 'get_state', timeout)
        before = fake.counter
        with pytest.raises(AppError, match='wire state timeout'):
            a.call('controller_verify', wait=1)
        assert wait(lambda: fake.counter > before and hub.controller.status().connected)
        assert a.call('controller_verify', wait=1)['neutral']
        assert all(state.is_neutral() for _, state in fake.states)
    finally:
        a.close()


def test_wire_verification_rechecks_ownership_after_wait(hub, monkeypatch):
    import concurrent.futures
    a, b = connect(hub), connect(hub)
    entered, unblock = threading.Event(), threading.Event()
    link = hub.controller.link()
    original = link.get_state
    def delayed(*args, **kwargs):
        entered.set()
        assert unblock.wait(2)
        return original(*args, **kwargs)
    monkeypatch.setattr(link, 'get_state', delayed)
    try:
        a.claim('first')
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(a.call, 'controller_verify', wait=1)
            assert entered.wait(1)
            a.unclaim()
            assert b.claim('second')['granted']
            unblock.set()
            with pytest.raises(AppError, match='Ownership changed'):
                future.result(timeout=3)
    finally:
        unblock.set()
        a.close()
        b.close()


def test_uninstall_reaches_padd_only_when_it_can_uninstall(hub, fake):
    client = connect(hub)
    try:
        with pytest.raises(AppError, match="Invalid argument"):
            client.command("uninstall", "not-a-title")
        assert client.command("uninstall", "PPSA01325") == 0
        assert (p.Command.UNINSTALL, "PPSA01325") in fake.commands
    finally:
        client.close()
    fake.flags &= ~p.FLAG_UNINSTALL
    fake.drop()  # the next HELLO lacks the flag
    assert wait(lambda: hub.controller.status().connected and hub.controller.reconnects > 0)
    client = connect(hub)
    try:
        with pytest.raises(AppError, match="padd 1.3"):
            client.command("uninstall", "PPSA01325")
        assert fake.commands.count((p.Command.UNINSTALL, "PPSA01325")) == 1
    finally:
        client.close()


async def test_uninstall_apps_tool(hub, fake, monkeypatch):
    monkeypatch.setattr(server, "HOST", "127.0.0.1")
    monkeypatch.setattr(server, "runtime", server.Runtime())
    server.runtime.start()
    try:
        assert await server.uninstall_apps(["PPSA01325"]) == [f"PPSA01325: {p.uninstall_text(0)}"]
    finally:
        server.runtime.stop()
