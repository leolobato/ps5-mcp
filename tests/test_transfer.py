"""push/pull against a local FTP server standing in for zftpd (pyftpdlib), with Payload Manager faked."""

from __future__ import annotations

import os
import socket
import threading
import time

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
    def __init__(self, root, port):
        authorizer = DummyAuthorizer()
        authorizer.add_anonymous(str(root), perm="elradfmwMT")
        handler = type("Handler", (FTPHandler,), {"authorizer": authorizer})
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
    src = make_source(tmp_path)
    summary = transfer.push("127.0.0.1", src, "/data/t/", lambda line: None, port=free_port(), autostart=False)
    assert calls == ["/data/t/title"] and "Web File Manager" in summary


def test_autostart_needs_zftpd_in_payload_manager(tmp_path, monkeypatch):
    monkeypatch.setattr(transfer, "_payload", lambda host: None)
    assert transfer.connect("127.0.0.1", free_port(), autostart=True) is None
