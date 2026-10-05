"""push/pull against a local FTP server standing in for zftpd (pyftpdlib), with Payload Manager faked."""

from __future__ import annotations

import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer

from ps5mcp import transfer


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Server:
    def __init__(self, root, port, handler_class=FTPHandler):
        authorizer = DummyAuthorizer()
        authorizer.add_anonymous(str(root), perm="elradfmwMT")
        handler = type("Handler", (handler_class,), {"authorizer": authorizer})
        self.ftpd = FTPServer(("127.0.0.1", port), handler)
        self.stopped = False
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def _loop(self):
        while not self.stopped:
            self.ftpd.serve_forever(timeout=0.05, blocking=False, handle_exit=False)

    def stop(self):
        self.stopped = True
        self.thread.join()
        self.ftpd.close_all()


@pytest.fixture
def console(tmp_path):
    root = tmp_path / "console"
    root.mkdir()
    port = free_port()
    server = Server(root, port)
    yield root, port
    server.stop()


def run(fn, *args, port, **kwargs):
    lines = []
    summary = fn("127.0.0.1", *args, lines.append, port=port, autostart=False, **kwargs)
    return summary, lines


def tree(path):
    return {p.relative_to(path).as_posix(): p.read_bytes() for p in sorted(path.rglob("*")) if p.is_file()}


def make_source(tmp_path):
    src = tmp_path / "title"
    (src / "sce_sys").mkdir(parents=True)
    (src / "eboot.bin").write_bytes(os.urandom(3 << 20))
    (src / "sce_sys" / "param.json").write_text("{}")
    old = time.time() - 600
    for p in src.rglob("*"):
        os.utime(p, (old, old))
    return src


def test_push_folder_then_skip_unchanged_and_resend_changed(console, tmp_path):
    root, port = console
    src = make_source(tmp_path)
    summary, _ = run(transfer.push, src, "/data/homebrew/FAKE1", port=port)
    assert "sent 2 files" in summary and "zftpd" in summary
    assert tree(root / "data/homebrew/FAKE1") == tree(src)

    summary, _ = run(transfer.push, src, "/data/homebrew/FAKE1", port=port)
    assert "sent 0 files" in summary and "2 unchanged skipped" in summary

    (src / "sce_sys" / "param.json").write_text('{"titleId": "FAKE1"}')
    summary, _ = run(transfer.push, src, "/data/homebrew/FAKE1", port=port)
    assert "sent 1 file " in summary and "1 unchanged skipped" in summary
    assert tree(root / "data/homebrew/FAKE1") == tree(src)

    summary, _ = run(transfer.push, src, "/data/homebrew/FAKE1", port=port, force=True)
    assert "sent 2 files" in summary


def test_push_resumes_a_partial_upload(console, tmp_path):
    root, port = console
    src = make_source(tmp_path)
    data = (src / "eboot.bin").read_bytes()
    (root / "dst").mkdir()
    (root / "dst" / "eboot.bin").write_bytes(data[:1 << 20])  # newer than the source: an interrupted upload
    summary, _ = run(transfer.push, src / "eboot.bin", "/dst/", port=port)
    assert "1 resumed" in summary and f"{(len(data) - (1 << 20)) / 1e6:.1f} MB" in summary
    assert (root / "dst" / "eboot.bin").read_bytes() == data


def test_older_partial_is_sent_again(console, tmp_path):
    root, port = console
    src = make_source(tmp_path)
    (root / "eboot.bin").write_bytes(b"x" * 100)
    os.utime(root / "eboot.bin", (0, 0))  # older than the source: a different file, not a partial copy
    summary, _ = run(transfer.push, src / "eboot.bin", "/eboot.bin", port=port)
    assert "resumed" not in summary
    assert (root / "eboot.bin").read_bytes() == (src / "eboot.bin").read_bytes()


def test_pull_folder_keeps_times_skips_and_resumes(console, tmp_path):
    root, port = console
    src = make_source(tmp_path)
    (root / "logs").mkdir()
    for p in src.rglob("*"):
        target = root / "logs" / p.relative_to(src)
        target.mkdir(exist_ok=True) if p.is_dir() else target.write_bytes(p.read_bytes())
    out = tmp_path / "out"
    out.mkdir()
    summary, _ = run(transfer.pull, "/logs", out, port=port)
    assert "received 2 files" in summary
    assert tree(out / "logs") == tree(src)

    summary, _ = run(transfer.pull, "/logs", out, port=port)
    assert "2 unchanged skipped" in summary

    big = out / "logs" / "eboot.bin"
    big.write_bytes(big.read_bytes()[:12345])  # interrupted download: shorter and newer
    summary, _ = run(transfer.pull, "/logs/eboot.bin", big, port=port)
    assert "1 resumed" in summary
    assert big.read_bytes() == (src / "eboot.bin").read_bytes()


def test_trailing_slash_copies_into_the_folder(console, tmp_path):
    root, port = console
    src = make_source(tmp_path)
    run(transfer.push, src / "eboot.bin", "/a/b/", port=port)
    assert (root / "a/b/eboot.bin").is_file()
    run(transfer.push, src / "eboot.bin", "/a/renamed.bin", port=port)
    assert (root / "a/renamed.bin").is_file()


def test_bad_paths(console, tmp_path):
    _, port = console
    src = make_source(tmp_path)
    with pytest.raises(ValueError, match="absolute"):
        run(transfer.push, src, "data/x", port=port)
    with pytest.raises(ValueError, match="does not exist"):
        run(transfer.pull, "/nope", tmp_path, port=port)
    run(transfer.push, src / "eboot.bin", "/dir/eboot.bin", port=port)
    with pytest.raises(ValueError, match="is a folder"):
        run(transfer.push, src / "eboot.bin", "/dir", port=port)


def test_autostart_loads_zftpd_from_payload_manager(tmp_path, monkeypatch):
    root = tmp_path / "console"
    root.mkdir()
    port = free_port()
    servers, loaded, checked = [], [], []

    class FakeConsole:
        def __init__(self, host):
            pass

        def request(self, port_, path, *args, **kwargs):
            assert port_ == 8084
            loaded.append(path)
            servers.append(Server(root, port))
            return b"OK"

    monkeypatch.setattr(transfer, "Console", FakeConsole)
    monkeypatch.setattr(transfer, "_payload", lambda host: "/data/pldmgr/payloads/zftpd/zftpd.elf")
    src = make_source(tmp_path)
    try:
        summary = transfer.push("127.0.0.1", src, "/t", lambda line: None, port=port, autostart=True,
                                before_start=lambda: checked.append(True))
    finally:
        for s in servers:
            s.stop()
    assert loaded == ["/loadpayload:/data/pldmgr/payloads/zftpd/zftpd.elf"] and checked == [True]
    assert "sent 2 files" in summary and tree(root / "t") == tree(src)


def test_without_zftpd_push_falls_back_to_web_file_manager(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(transfer, "_wfm_push", lambda host, source, target, progress, stats: calls.append(target))
    src = tmp_path / "title"
    src.mkdir()
    (src / "asset.txt").write_text("asset")
    summary = transfer.push("127.0.0.1", src, "/data/t/", lambda line: None, port=free_port(), autostart=False)
    assert calls == ["/data/t/title"] and "Web File Manager" in summary


def test_autostart_needs_zftpd_in_payload_manager(tmp_path, monkeypatch):
    monkeypatch.setattr(transfer, "_payload", lambda host: None)
    assert transfer.connect("127.0.0.1", free_port(), autostart=True) is None


class ResetModesHandler(FTPHandler):
    """Uploads start without execute bits, including overwrites."""
    def on_file_received(self, file):
        os.chmod(file, 0o666)


class RejectChmodHandler(ResetModesHandler):
    def ftp_SITE_CHMOD(self, path, mode):
        self.respond("550 SITE CHMOD unavailable")


class IgnoreChmodHandler(ResetModesHandler):
    def ftp_SITE_CHMOD(self, path, mode):
        self.respond("200 CHMOD successful")


@pytest.mark.parametrize("force", [False, True])
def test_native_upload_repairs_fresh_skipped_and_overwritten_files(tmp_path, force):
    root = tmp_path / "remote"
    root.mkdir()
    port = free_port()
    ftp_server = Server(root, port, ResetModesHandler)
    src = make_source(tmp_path)
    (src / "sce_module").mkdir()
    (src / "sce_module/libc.prx").write_bytes(b"module")
    (src / "sce_module/extra.sprx").write_bytes(b"module")
    (src / "helper").write_bytes(b"helper")
    (src / "helper").chmod(0o755)
    try:
        for repeat in range(2):
            summary, _ = run(transfer.push, src, "/title", port=port, force=force)
            for name in ("eboot.bin", "sce_module/libc.prx", "sce_module/extra.sprx", "helper"):
                path = root / "title" / name
                assert path.stat().st_mode & 0o777 == 0o755
                path.chmod(0o666)
            assert not (root / "title/sce_sys/param.json").stat().st_mode & 0o111
            assert "permissions verified" in summary
    finally:
        ftp_server.stop()


@pytest.mark.parametrize("handler", [RejectChmodHandler, IgnoreChmodHandler])
def test_native_upload_fails_when_permissions_cannot_be_restored(tmp_path, handler):
    root = tmp_path / "remote"
    root.mkdir()
    port = free_port()
    ftp_server = Server(root, port, handler)
    try:
        with pytest.raises(RuntimeError, match="eboot.bin.*(CHMOD|execute)"):
            run(transfer.push, make_source(tmp_path), "/title", port=port)
    finally:
        ftp_server.stop()


def test_native_upload_requires_ftp_before_using_web_fallback(tmp_path, monkeypatch):
    monkeypatch.setattr(transfer, "connect", lambda *args: None)
    with pytest.raises(RuntimeError, match="zftpd.*permission"):
        transfer.push("127.0.0.1", make_source(tmp_path), "/title")


@pytest.fixture
def shadowmount():
    snapshots = []
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            assert self.path == "/api/v1/games"
            self.rfile.read(int(self.headers["Content-Length"]))
            data = snapshots.pop(0) if len(snapshots) > 1 else snapshots[0]
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())

        def log_message(self, *args):
            pass
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield snapshots, httpd.server_port
    httpd.shutdown()
    thread.join()
    httpd.server_close()


def test_title_upload_waits_for_registration_of_matching_source(console, tmp_path, shadowmount, monkeypatch):
    root, port = console
    snapshots, smp_port = shadowmount
    monkeypatch.setattr(transfer, "SMP_PORT", smp_port, raising=False)
    src = make_source(tmp_path)
    (src / "sce_sys/param.json").write_text('{"titleId":"PPSA99764"}')
    snapshots.extend([
        {"games": []},
        {"games": [{"title_id": "PPSA99764", "path": "/old", "installed": True,
                    "managed": True, "source_available": True}]},
        {"games": [{"title_id": "PPSA99764", "path": "/title", "installed": True,
                    "managed": True, "source_available": True}]},
    ])
    summary, _ = run(transfer.push, src, "/title", port=port)
    assert "registration verified: PPSA99764" in summary
    assert len(snapshots) == 1
    assert (root / "title/eboot.bin").stat().st_mode & 0o111 == 0o111


def test_registration_timeout_does_not_claim_readiness(shadowmount, monkeypatch):
    snapshots, smp_port = shadowmount
    monkeypatch.setattr(transfer, "SMP_PORT", smp_port, raising=False)
    snapshots.append({"games": [{"title_id": "PPSA99764", "path": "/title", "installed": False,
                                  "managed": True, "source_available": True}]})
    with pytest.raises(TimeoutError, match="registration.*PPSA99764"):
        transfer.wait_registration("127.0.0.1", "PPSA99764", "/title", timeout=0.05)


def test_unavailable_registration_api_has_actionable_error(monkeypatch):
    monkeypatch.setattr(transfer, "SMP_PORT", free_port(), raising=False)
    with pytest.raises(RuntimeError, match="registration.*API.*(LAN|bind)"):
        transfer.wait_registration("127.0.0.1", "PPSA99764", "/title", timeout=0.05)


class UnixModeHandler(ResetModesHandler):
    def on_connect(self):
        self._current_facts.append("unix.mode")


class NoModesHandler(ResetModesHandler):
    def ftp_LIST(self, path):
        self.respond("502 LIST unavailable")


@pytest.mark.parametrize("handler", [UnixModeHandler, NoModesHandler])
def test_mode_readback_is_required_after_chmod(tmp_path, handler):
    root = tmp_path / "remote"
    root.mkdir()
    port = free_port()
    ftp_server = Server(root, port, handler)
    try:
        if handler is NoModesHandler:
            with pytest.raises(RuntimeError, match="eboot.bin.*verify.*permissions"):
                run(transfer.push, make_source(tmp_path), "/title", port=port)
        else:
            summary, _ = run(transfer.push, make_source(tmp_path), "/title", port=port)
            assert "permissions verified" in summary
            assert (root / "title/eboot.bin").stat().st_mode & 0o111 == 0o111
    finally:
        ftp_server.stop()


def test_individual_native_module_upload_restores_permissions(console, tmp_path):
    root, port = console
    module = tmp_path / "libc.prx"
    module.write_bytes(b"module")
    module.chmod(0o644)
    run(transfer.push, module, "/title/sce_module/", port=port)
    assert (root / "title/sce_module/libc.prx").stat().st_mode & 0o777 == 0o755


def test_enclosing_folder_identifies_nested_title_root(tmp_path):
    title = tmp_path / "distribution/PPSA99764"
    (title / "sce_sys").mkdir(parents=True)
    (title / "eboot.bin").write_bytes(b"executable")
    (title / "sce_sys/param.json").write_text('{"titleId":"PPSA99764"}')
    assert transfer.native_titles(title.parent, "/data/homebrew") == [
        ("PPSA99764", "/data/homebrew/PPSA99764")]
