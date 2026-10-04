"""padd daemon logic, compiled for the Mac against a recording stub (make build/padd-host)."""

from __future__ import annotations

import json
import signal
import socket
import subprocess
import time
from pathlib import Path

import pytest

from ps5mcp import protocol as p
from ps5mcp.client import HumanHasControl, PadBusy, PadController, PadError, PadLink
from ps5mcp.protocol import PadState

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "build/padd-host"
RIGHT = p.BUTTONS["right"]

pytestmark = pytest.mark.skipif(not BINARY.exists(), reason="run make build/padd-host")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Padd:
    def __init__(self, tmp: Path, *args: str, env: dict | None = None):
        self.port = free_port()
        self.logs = tmp / "logs"
        self.trace = tmp / "trace.jsonl"
        self.process = subprocess.Popen(
            [str(BINARY), "--port", str(self.port), "--log-dir", str(self.logs), *args],
            env={"PADD_TRACE": str(self.trace), **(env or {})})
        deadline = time.monotonic() + 5
        while not any(e.get("event") == "pad_added" for e in self.events()):
            if time.monotonic() > deadline or self.process.poll() is not None:
                raise RuntimeError(f"padd-host did not start: {self.events()}")
            time.sleep(0.02)

    def events(self) -> list[dict]:
        logs = list(self.logs.glob("padd-*")) if self.logs.exists() else []
        return [json.loads(line) for log in logs for line in log.read_text().splitlines() if line]

    def calls(self, name: str | None = None) -> list[dict]:
        if not self.trace.exists():
            return []
        calls = [json.loads(line) for line in self.trace.read_text().splitlines() if line]
        return [c for c in calls if name is None or c["call"] == name]

    def last_buttons(self) -> int:
        return self.calls("pad_report")[-1]["buttons"]

    def connect(self) -> PadLink:
        return PadLink("127.0.0.1", self.port)

    def stop(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            self.process.wait(5)


@pytest.fixture
def padd(tmp_path):
    daemon = Padd(tmp_path)
    yield daemon
    daemon.stop()


def wait_for(predicate, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def test_hello_reports_ready_pad_for_foreground_user(padd):
    link = padd.connect()
    assert link.hello.pad_ready and link.hello.pad_handle == 1000
    assert link.hello.user_id == 0x11ECF8B9 and link.hello.protocol == p.VERSION
    assert padd.calls("pad_add")[0]["user_id"] == 0x11ECF8B9
    link.close()


def test_state_is_acked_and_reaches_the_pad(padd):
    link = padd.connect()
    assert link.send_state(PadState(buttons=RIGHT, lx=0), wait=True) == 0
    assert padd.last_buttons() == RIGHT
    assert padd.calls("pad_report")[-1]["lx"] == 0
    assert link.get_state().buttons == RIGHT
    link.close()


def test_ping_reports_uptime_and_counters(padd):
    link = padd.connect()
    link.send_state(PadState(buttons=RIGHT), wait=True)
    pong = link.ping()
    assert pong.protocol == 1 and p.version_string(pong.payload_version) == "1.3"
    assert pong.reports_sent >= 1 and pong.report_failures == 0 and pong.flags & p.FLAG_PAD_READY
    link.close()


def test_watchdog_releases_after_one_second_without_state(padd):
    link = padd.connect()
    link.send_state(PadState(buttons=RIGHT), wait=True)
    time.sleep(0.6)
    link.ping()  # activity that is not a STATE must not keep a button held
    assert padd.last_buttons() == RIGHT
    assert wait_for(lambda: padd.last_buttons() == 0, 1.5)
    assert {"event": "neutral", "reason": "watchdog"} in padd.events()
    assert link.ping().neutral_events == 1
    link.close()


def test_disconnect_releases_everything(padd):
    link = padd.connect()
    link.send_state(PadState(buttons=RIGHT, r2=255), wait=True)
    link.close()
    assert wait_for(lambda: padd.last_buttons() == 0)
    assert padd.calls("pad_report")[-1]["r2"] == 0
    assert {"event": "neutral", "reason": "disconnect"} in padd.events()


def test_second_client_is_rejected_as_busy(padd):
    first = padd.connect()
    with pytest.raises(PadBusy):
        padd.connect()
    first.close()
    assert wait_for(lambda: any(e.get("event") == "client_closed" for e in padd.events()))
    padd.connect().close()


def test_silent_client_is_dropped(tmp_path):
    daemon = Padd(tmp_path, "--idle-ms", "400")
    try:
        link = daemon.connect()
        assert wait_for(lambda: link.closed, 2)
        assert {"event": "client_closed", "reason": "idle"} in daemon.events()
    finally:
        daemon.stop()


def test_only_one_instance_runs(padd, tmp_path):
    second = subprocess.run([str(BINARY), "--port", str(padd.port), "--log-dir", str(tmp_path / "second")],
                            timeout=5, check=False)
    assert second.returncode == 3
    events = [json.loads(line) for log in (tmp_path / "second").glob("padd-*")
              for line in log.read_text().splitlines()]
    assert events[-2]["event"] == "already_running" and events[-1] == {"event": "exit_requested", "code": 3}
    assert len(padd.calls("pad_add")) == 1


def test_shutdown_removes_pad_and_exits_cleanly(padd):
    link = padd.connect()
    link.send_state(PadState(buttons=RIGHT), wait=True)
    link.shutdown()
    assert padd.process.wait(3) == 0
    assert padd.last_buttons() == 0
    assert padd.calls("pad_remove") == [{"call": "pad_remove", "handle": 1000}]
    assert padd.events()[-1] == {"event": "exit_requested", "code": 0}


def test_sigterm_removes_pad(padd):
    padd.process.send_signal(signal.SIGTERM)
    assert padd.process.wait(3) == 0
    assert padd.calls("pad_remove")


def test_commands_report_system_status(padd):
    link = padd.connect()
    assert link.command(p.Command.HOME) == 0
    assert link.command(p.Command.HOME, "suspend") == 0
    assert link.command(p.Command.HOME, "bogus") == 22
    assert link.command(p.Command.CLOSE) == 0
    assert link.command(p.Command.LAUNCH, "PPSA01325") == 0
    assert link.command(p.Command.LAUNCH, "BADTITLE") == -0x7F6BFFFB  # 0x80940005 as int32
    assert [c["call"] for c in padd.calls()][-6:] == ["go_home", "go_home", "go_home", "close_app", "launch", "launch"]
    assert [c.get("method") for c in padd.calls("go_home")] == ["", "suspend", "bogus"]
    assert padd.calls("launch")[0] == {"call": "launch", "title_id": "PPSA01325", "user_id": 0x11ECF8B9}
    link.close()


def test_uninstall_reaches_the_system_with_valid_ids_only(padd):
    link = padd.connect()
    assert link.hello.flags & p.FLAG_UNINSTALL
    assert link.command(p.Command.UNINSTALL, "PPSA01325") == 0
    assert link.command(p.Command.UNINSTALL, "BUSY00001") == -0x7F5CFFFB  # 0x80A30005 as int32
    for bad in ("", "PPSA0132", "PPSA013250", "ppsa01325", "PPSA0132X", "../../etc"):
        assert link.command(p.Command.UNINSTALL, bad) == 22  # EINVAL, never passed on
    assert [c["title_id"] for c in padd.calls("uninstall")] == ["PPSA01325", "BUSY00001"]
    link.close()


class FakeSmp:
    """ShadowMountPlus's API as padd uses it: delete answers `delete`, the job stays active for `active_polls`, then
    ends with `result` (an errno; 0 completes it). Status reports job `status_job` (another job replaced ours)."""

    def __init__(self, delete: int = 202, active_polls: int = 1, result: int = 0, status_job: int = 1,
                 delete_error: str = "game source not found"):
        import http.server
        import threading
        self.requests: list[tuple[str, dict]] = []
        self.delete, self.active_polls, self.result, self.status_job = delete, active_polls, result, status_job
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"{}")
                fake.requests.append((self.path, body))
                if self.path == "/api/v1/games/delete":
                    code, reply = fake.delete, ({"status": 0, "job_id": 1, "state": "running", "active": True}
                                                if fake.delete == 202 else {"status": 16, "error": delete_error})
                else:
                    active = fake.active_polls > 0
                    fake.active_polls -= 1
                    state = "running" if active else "failed" if fake.result else "completed"
                    code, reply = 200, {"status": 0, "job_id": fake.status_job, "state": state, "active": active,
                                        "result_status": 0 if active else fake.result}
                data = json.dumps(reply, indent=1).encode()  # json-c style spacing: "active": true
                self.send_response(code)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def paths(self) -> list[str]:
        return [path for path, _ in self.requests]


def smp_padd(tmp_path, smp_port: int, managed: tuple[str, ...]) -> Padd:
    apps = tmp_path / "app"
    for title in managed:
        (apps / title).mkdir(parents=True)
        (apps / title / "mount.lnk").write_text(f"/data/homebrew/{title}")
    return Padd(tmp_path, "--smp-port", str(smp_port), "--app-dir", str(apps))


def test_uninstall_deletes_a_shadowmount_source_first(tmp_path):
    smp = FakeSmp(active_polls=2)
    padd = smp_padd(tmp_path, smp.port, ("FAKE77001",))
    try:
        link = padd.connect()
        assert link.command(p.Command.UNINSTALL, "FAKE77001") == 0
        assert smp.requests[0] == ("/api/v1/games/delete", {"title_id": "FAKE77001", "confirm": True})
        assert smp.paths()[1:] == ["/api/v1/games/storage/status"] * 3  # active, active, done
        assert [c["title_id"] for c in padd.calls("uninstall")] == ["FAKE77001"]
        assert link.command(p.Command.UNINSTALL, "PPSA01325") == 0  # not SMP's: no request to it
        assert len(smp.requests) == 4 and len(padd.calls("uninstall")) == 2
        link.close()
    finally:
        padd.stop()
        smp.server.shutdown()


@pytest.mark.parametrize(("delete", "polls", "status"), [(409, 0, 16), (500, 0, 5), (202, 100, 36), (404, 0, 0)])
def test_shadowmount_uninstall_outcomes(tmp_path, delete, polls, status):
    smp = FakeSmp(delete=delete, active_polls=polls)
    padd = smp_padd(tmp_path, smp.port, ("FAKE77001",))
    try:
        link = padd.connect()
        assert link.command(p.Command.UNINSTALL, "FAKE77001") == status  # EBUSY, EIO, EINPROGRESS, or uninstalled
        assert len(padd.calls("uninstall")) == (1 if status == 0 else 0)
        link.command(p.Command.HOME)  # still connected after the wait
        link.close()
    finally:
        padd.stop()
        smp.server.shutdown()


@pytest.mark.parametrize(("smp", "status"), [
    ({"result": 13}, 13),                                         # EACCES: SMP could not delete the source
    ({"status_job": 2}, 16),                                      # another job replaced ours: EBUSY, retry
    ({"delete": 404, "delete_error": "unknown API route"}, 45),  # SMP without source delete: ENOTSUP
])
def test_shadowmount_title_stays_installed_when_its_source_remains(tmp_path, smp, status):
    fake = FakeSmp(**smp)
    padd = smp_padd(tmp_path, fake.port, ("FAKE77001",))
    try:
        link = padd.connect()
        assert link.command(p.Command.UNINSTALL, "FAKE77001") == status
        assert not padd.calls("uninstall")  # SMP's next scan would install it again
        link.close()
    finally:
        padd.stop()
        fake.server.shutdown()


def test_shadowmount_title_without_shadowmount_running_is_refused(tmp_path):
    padd = smp_padd(tmp_path, free_port(), ("FAKE77001",))
    try:
        link = padd.connect()
        assert link.command(p.Command.UNINSTALL, "FAKE77001") == 61  # ECONNREFUSED: it would come back
        assert not padd.calls("uninstall")
        link.close()
    finally:
        padd.stop()


def test_bad_magic_gets_error_and_disconnect(padd):
    with socket.create_connection(("127.0.0.1", padd.port)) as raw:
        raw.recv(64)  # HELLO
        raw.sendall(b"XXXX\x01\x02\x00\x00")
        reader = p.Reader()
        messages = []
        while not messages:
            messages = reader.feed(raw.recv(64))
        assert messages[0][0] == p.Type.ERROR and p.decode_error(messages[0][1])[0] == p.Error.BAD_MAGIC
        assert raw.recv(64) == b""


def test_missing_pad_is_reported_not_fatal(tmp_path):
    daemon = Padd(tmp_path, env={"PADD_FAIL_ADD": "22"})
    try:
        link = daemon.connect()
        assert not link.hello.pad_ready and link.hello.add_status == 22
        assert link.send_state(PadState(buttons=RIGHT), wait=True) == p.Error.NO_PAD
        link.close()
    finally:
        daemon.stop()


def test_controller_streams_and_keyboard_has_priority(padd):
    controller = PadController("127.0.0.1", padd.port, keepalive=0.05)
    try:
        controller.link(wait=3)
        controller.set_agent(PadState(buttons=RIGHT))
        assert wait_for(lambda: padd.last_buttons() == RIGHT)
        controller.key("Enter", PadState(buttons=p.BUTTONS["cross"]))
        assert wait_for(lambda: padd.last_buttons() == p.BUTTONS["cross"])  # agent hold cancelled
        with pytest.raises(HumanHasControl):
            controller.set_agent(PadState(buttons=RIGHT))
        controller.key("Enter", None)
        assert wait_for(lambda: padd.last_buttons() == 0)
        controller.set_agent(PadState(buttons=RIGHT))
        time.sleep(1.5)  # keepalive keeps a deliberate hold alive past the watchdog
        assert padd.last_buttons() == RIGHT
        assert {"event": "neutral", "reason": "watchdog"} not in padd.events()
    finally:
        controller.close()
    assert wait_for(lambda: padd.last_buttons() == 0)


def test_controller_reconnects_with_neutral_state(tmp_path):
    daemon = Padd(tmp_path)
    port = daemon.port
    controller = PadController("127.0.0.1", port, keepalive=0.05)
    try:
        controller.link(wait=3)
        controller.set_agent(PadState(buttons=RIGHT))
        daemon.stop()
        assert wait_for(lambda: not controller.status().connected)
        restarted = subprocess.Popen([str(BINARY), "--port", str(port), "--log-dir", str(tmp_path / "logs2")],
                                     env={"PADD_TRACE": str(tmp_path / "trace2.jsonl")})
        try:
            controller.link(wait=8)
            assert controller.current().is_neutral()
            assert controller.status().reconnects == 1
        finally:
            restarted.send_signal(signal.SIGTERM)
            restarted.wait(5)
    finally:
        controller.close(neutral=False)


def test_link_to_nothing_raises(tmp_path):
    with pytest.raises(OSError):
        PadLink("127.0.0.1", free_port(), timeout=0.5)
    controller = PadController("127.0.0.1", free_port())
    with pytest.raises(PadError, match="not connected"):
        controller.link(wait=0.3)
    controller.close(neutral=False)


def test_user_name_lookup_reports_the_pad_user(padd):
    link = padd.connect()
    try:
        user = link.get_user()
        assert user is not None and user.status == 0
        assert user.user_id == link.hello.user_id and user.name == "Test Player"
    finally:
        link.close()


def test_user_name_lookup_handles_utf8(tmp_path):
    daemon = Padd(tmp_path, env={"PADD_USER_NAME": "Léo 🎮"})
    try:
        link = daemon.connect()
        try:
            assert link.get_user().name == "Léo 🎮"
        finally:
            link.close()
    finally:
        daemon.stop()


def test_user_name_lookup_failure_preserves_connection(tmp_path):
    daemon = Padd(tmp_path, env={"PADD_FAIL_USER_NAME": "38"})
    try:
        link = daemon.connect()
        try:
            user = link.get_user()
            assert user.status == 38 and user.name == ""
            assert link.ping().pad_handle == link.hello.pad_handle
        finally:
            link.close()
    finally:
        daemon.stop()


def test_user_name_request_is_skipped_without_capability(padd, monkeypatch):
    from dataclasses import replace
    link = padd.connect()
    try:
        link.hello = replace(link.hello, flags=link.hello.flags & ~p.FLAG_USER_NAME)

        def unexpected_request(*args):
            pytest.fail("username request sent to a payload without the capability")

        monkeypatch.setattr(link, "_request", unexpected_request)
        assert link.get_user() is None
    finally:
        link.close()
