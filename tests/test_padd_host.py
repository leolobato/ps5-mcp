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
    assert pong.protocol == 1 and p.version_string(pong.payload_version) == "1.10"
    assert pong.reports_sent >= 1 and pong.report_failures == 0 and pong.flags & p.FLAG_PAD_READY
    link.close()


def test_watchdog_releases_after_one_second_without_state(padd):
    link = padd.connect()
    link.send_state(PadState(buttons=RIGHT), wait=True)
    time.sleep(0.6)
    link.ping()  # activity that is not a STATE must not keep a button held
    assert padd.last_buttons() == RIGHT
    assert wait_for(lambda: padd.last_buttons() == 0, 1.5)
    assert {"event": "neutral", "reason": "watchdog", "pad": 1} in padd.events()
    assert link.ping().neutral_events == 1
    link.close()


def test_disconnect_releases_everything(padd):
    link = padd.connect()
    link.send_state(PadState(buttons=RIGHT, r2=255), wait=True)
    link.close()
    assert wait_for(lambda: padd.last_buttons() == 0)
    assert padd.calls("pad_report")[-1]["r2"] == 0
    assert {"event": "neutral", "reason": "disconnect", "pad": 1} in padd.events()


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


def test_slow_command_does_not_count_as_a_silent_client(tmp_path):
    # The console's launch can block padd's loop for seconds; the client's keepalives wait unread meanwhile.
    daemon = Padd(tmp_path, "--idle-ms", "400", env={"PADD_LAUNCH_DELAY_MS": "700"})
    try:
        link = daemon.connect()
        assert link.command(p.Command.LAUNCH, "PPSA01325") == 0
        assert link.ping(timeout=1).protocol == p.VERSION
        assert {"event": "client_closed", "reason": "idle"} not in daemon.events()
        link.close()
    finally:
        daemon.stop()


def test_a_client_that_hung_up_does_not_make_the_next_one_busy(tmp_path):
    # On the console, padd's loop is slow enough that the old client's close and the next connect arrive together.
    daemon = Padd(tmp_path, env={"PADD_LAUNCH_DELAY_MS": "500"})
    try:
        old = socket.create_connection(("127.0.0.1", daemon.port))
        old.sendall(p.encode_command(1, p.Command.LAUNCH, "PPSA01325"))
        time.sleep(0.2)  # padd is inside the slow launch
        old.close()
        PadLink("127.0.0.1", daemon.port).close()  # queued behind the close, not rejected as busy
        assert {"event": "client_rejected", "reason": "busy"} not in daemon.events()
    finally:
        daemon.stop()


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
        assert {"event": "neutral", "reason": "watchdog", "pad": 1} not in padd.events()
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



GUEST = 0x22334455


TWO_USERS = {"PADD_LOGIN_USERS": f"{0x11ECF8B9},{GUEST}"}


def reports(daemon, handle: int) -> list[int]:
    return [c["buttons"] for c in daemon.calls("pad_report") if c["handle"] == handle]


def test_second_pad_drives_while_selected_and_the_first_stays_neutral(tmp_path):
    daemon = Padd(tmp_path, env=TWO_USERS)
    try:
        link = daemon.connect()
        assert link.hello.flags & p.FLAG_PADS and not link.hello.flags & p.FLAG_PAD_USER
        assert link.get_pads() == p.Pads(1, (1000, -1, -1, -1), (0x11ECF8B9, -1, -1, -1))
        link.send_state(PadState(buttons=RIGHT), wait=True)
        assert link.command(p.Command.PAD, "connect") == 0
        assert daemon.calls("pad_add")[-1]["user_id"] == GUEST and not daemon.calls("pad_remove")
        assert reports(daemon, 1001) == [0]  # fed from the start, neutral
        assert link.get_pads() == p.Pads(1, (1000, 1001, -1, -1), (0x11ECF8B9, GUEST, -1, -1))  # connecting does not select it
        assert link.command(p.Command.SELECT_PAD, "2") == 0
        assert reports(daemon, 1000)[-1] == 0  # the held Right is released on pad 1
        assert link.get_user().user_id == GUEST and link.ping().pad_handle == 1001
        assert link.send_state(PadState(buttons=RIGHT), wait=True) == 0
        assert reports(daemon, 1001)[-1] == RIGHT and reports(daemon, 1000)[-1] == 0
        # The foreground user launches, even while pad 2 is selected.
        assert link.command(p.Command.LAUNCH, "PPSA01325") == 0
        assert daemon.calls("launch")[-1]["user_id"] == 0x11ECF8B9
        link.close()
        # A new client sees the pads as they are now; the disconnect released pad 2.
        assert wait_for(lambda: reports(daemon, 1001)[-1] == 0)
        link = daemon.connect()
        assert link.hello.user_id == GUEST and link.hello.pad_handle == 1001 and link.hello.pad_ready
        assert link.command(p.Command.SELECT_PAD, "1") == 0 and link.ping().pad_handle == 1000
        link.close()
    finally:
        daemon.stop()


def test_disconnecting_the_second_pad_selects_the_first(tmp_path):
    daemon = Padd(tmp_path, env=TWO_USERS)
    try:
        link = daemon.connect()
        assert link.command(p.Command.PAD, "connect") == 0
        assert link.command(p.Command.PAD, "connect") == 2  # nobody else is left: nothing changes
        assert link.command(p.Command.PAD, f"connect {GUEST}") == 0  # already connected: nothing changes
        assert len(daemon.calls("pad_add")) == 2
        assert link.command(p.Command.SELECT_PAD, "2") == 0
        link.send_state(PadState(buttons=RIGHT), wait=True)
        assert link.command(p.Command.PAD, "disconnect") == 0
        assert reports(daemon, 1001)[-1] == 0 and daemon.calls("pad_remove") == [{"call": "pad_remove", "handle": 1001}]
        assert link.get_pads() == p.Pads(1, (1000, -1, -1, -1), (0x11ECF8B9, -1, -1, -1))
        assert link.command(p.Command.SELECT_PAD, "2") == 2  # ENOENT: not connected
        assert link.command(p.Command.PAD, "disconnect") == 0
        assert link.send_state(PadState(buttons=RIGHT), wait=True) == 0 and reports(daemon, 1000)[-1] == RIGHT
        link.close()
    finally:
        daemon.stop()


def test_second_pad_needs_a_second_user_and_valid_args(padd):
    link = padd.connect()
    assert link.command(p.Command.PAD, "connect") == 2  # ENOENT: nobody else signed in
    assert link.command(p.Command.PAD, "") == 22
    assert link.command(p.Command.SELECT_PAD, "5") == 22
    assert link.command(p.Command.SELECT_PAD, "1") == 0
    assert len(padd.calls("pad_add")) == 1 and not padd.calls("pad_remove")
    assert p.pads_text("pad", 2) == p.PAD_ERRORS[2] and p.pads_text("select_pad", 2).startswith("that controller")
    with pytest.raises(PadError, match="unknown command op"):  # padd 1.5's PAD_USER is gone
        link.command(p.Command.PAD_USER, "second")
    link.close()


def test_second_pad_can_be_for_a_given_user(padd):
    # A user who is not signed in: on the console this opens the picker, where Cross on their profile signs them in.
    link = padd.connect()
    assert link.command(p.Command.PAD, "connect 0") == 22
    assert link.command(p.Command.PAD, "connect x1") == 22
    assert link.command(p.Command.PAD, "connectx") == 22
    assert link.command(p.Command.PAD, f"connect {GUEST}") == 0
    assert padd.calls("pad_add")[-1]["user_id"] == GUEST and link.get_pads().user_ids == (0x11ECF8B9, GUEST, -1, -1)
    link.close()


def test_a_pads_user_follows_what_the_client_reports(padd):
    # The console's picker can give a pad to another profile than the one it was added for; only the client sees it.
    other = 0x33445566
    link = padd.connect()
    assert link.hello.flags & p.FLAG_PAD_USERS
    assert link.command(p.Command.PAD, f"connect {GUEST}") == 0
    adds = len(padd.calls("pad_add"))
    assert link.command(p.Command.PAD, f"user 2 {other}") == 0
    assert link.get_pads() == p.Pads(1, (1000, 1001, -1, -1), (0x11ECF8B9, other, -1, -1))
    assert link.command(p.Command.PAD, f"connect {other}") == 0  # that user's controller is this one: nothing is added
    assert link.command(p.Command.PAD, f"connect {GUEST}") == 0  # and the first user is free again
    assert link.get_pads().user_ids == (0x11ECF8B9, other, GUEST, -1)
    assert link.command(p.Command.PAD, f"user 1 {GUEST}") == 0  # the first pad too; the client clears the other itself
    assert link.command(p.Command.PAD, "user 3 0") == 0  # nobody has it
    assert link.get_pads() == p.Pads(1, (1000, 1001, 1002, -1), (GUEST, other, -1, -1))
    assert link.get_user().user_id == GUEST  # the selected pad's user, as HELLO would say
    assert link.command(p.Command.PAD, "user 4 5") == 2  # ENOENT: not connected
    for bad in ("user", "user 2", "user 5 7", "user 2 -7", "user 2 x", "user 2 7x", "user 2  7", "user 2 99999999999"):
        assert link.command(p.Command.PAD, bad) == 22, bad
    # Only the record changed: no pad was added or removed for it.
    assert len(padd.calls("pad_add")) == adds + 1 and not padd.calls("pad_remove")
    link.close()


def test_four_pads_keep_their_numbers(tmp_path):
    other, third = GUEST + 1, GUEST + 2
    daemon = Padd(tmp_path, env={"PADD_LOGIN_USERS": f"{0x11ECF8B9},{GUEST},{other},{third}"})
    try:
        link = daemon.connect()
        for _ in range(3):
            assert link.command(p.Command.PAD, "connect") == 0
        assert link.get_pads().user_ids == (0x11ECF8B9, GUEST, other, third)
        assert link.command(p.Command.PAD, "connect") == 28  # ENOSPC: all four connected
        assert link.command(p.Command.PAD, f"connect {GUEST + 3}") == 28
        assert link.command(p.Command.PAD, f"connect {other}") == 0  # already connected: nothing changes
        assert len(daemon.calls("pad_add")) == 4

        # Input follows the selected pad only.
        assert link.command(p.Command.SELECT_PAD, "4") == 0 and link.ping().pad_handle == 1003
        assert link.send_state(PadState(buttons=RIGHT), wait=True) == 0
        assert reports(daemon, 1003)[-1] == RIGHT and reports(daemon, 1002)[-1] == 0

        # Removing another pad leaves the selection and every other number alone.
        for bad in ("disconnect 1", "disconnect 5", "disconnect x", "disconnect 22"):
            assert link.command(p.Command.PAD, bad) == 22
        assert link.command(p.Command.PAD, "disconnect 3") == 0
        pads = link.get_pads()
        assert pads.active == 4 and pads.handles == (1000, 1001, -1, 1003)
        assert reports(daemon, 1003)[-1] == RIGHT
        assert link.command(p.Command.PAD, "disconnect 3") == 0  # not connected: nothing changes
        assert link.command(p.Command.SELECT_PAD, "3") == 2

        # A new pad takes the lowest free number.
        assert link.command(p.Command.PAD, "connect") == 0
        assert link.get_pads().user_ids == (0x11ECF8B9, GUEST, other, third)
        assert link.get_pads().handles[2] == 1004

        # Removing the selected one releases it and goes back to pad 1; plain "disconnect" takes the highest.
        assert link.command(p.Command.PAD, "disconnect 4") == 0
        assert reports(daemon, 1003)[-1] == 0
        pads = link.get_pads()
        assert pads.active == 1 and pads.handles == (1000, 1001, 1004, -1)
        assert link.command(p.Command.PAD, "disconnect") == 0
        assert link.get_pads().handles == (1000, 1001, -1, -1)
        link.close()
    finally:
        daemon.stop()
    # Shutting down removes every pad.
    assert {c["handle"] for c in daemon.calls("pad_remove")} >= {1000, 1001}


def test_failed_second_pad_keeps_the_first(tmp_path):
    daemon = Padd(tmp_path, env={**TWO_USERS, "PADD_FAIL_ADD": "16", "PADD_FAIL_ADD_USER": str(GUEST)})
    try:
        link = daemon.connect()
        assert link.command(p.Command.PAD, "connect") == 16
        assert link.get_pads().handles == (1000, -1, -1, -1) and link.ping().pad_handle == 1000
        assert link.send_state(PadState(buttons=RIGHT), wait=True) == 0
        link.close()
    finally:
        daemon.stop()


def test_shutdown_removes_both_pads(tmp_path):
    daemon = Padd(tmp_path, env=TWO_USERS)
    try:
        link = daemon.connect()
        assert link.command(p.Command.PAD, "connect") == 0
        link.shutdown()
        assert wait_for(lambda: daemon.process.poll() is not None)
        assert sorted(c["handle"] for c in daemon.calls("pad_remove")) == [1000, 1001]
        events = [e["event"] for e in daemon.events()]
        assert "extra_pad_removed" in events and events.count("pad_removed") == 1
    finally:
        daemon.stop()


def test_users_lists_the_foreground_and_signed_in_users(tmp_path):
    daemon = Padd(tmp_path, env={"PADD_LOGIN_USERS": f"{GUEST},{0x11ECF8B9}", "PADD_GUEST_NAME": "User1"})
    try:
        link = daemon.connect()
        try:
            users = link.get_users()
            assert users.status == 0 and users.foreground == 0x11ECF8B9
            assert [(u.user_id, u.name) for u in users.users] == [(GUEST, "User1"), (0x11ECF8B9, "Test Player")]
        finally:
            link.close()
    finally:
        daemon.stop()


def test_users_without_a_sign_in_list_still_answers(tmp_path):
    daemon = Padd(tmp_path, env={"PADD_FAIL_LOGIN_USERS": "78"})
    try:
        link = daemon.connect()
        try:
            users = link.get_users()
            assert users.status == 78 and users.foreground == 0x11ECF8B9 and users.users == ()
            assert link.ping().pad_handle == link.hello.pad_handle
        finally:
            link.close()
    finally:
        daemon.stop()
