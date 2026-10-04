"""Copy files and folders between this Mac and the console: FTP through zftpd, Web File Manager as the fallback.

- zftpd (https://github.com/seregonwar/zftpd) listens on `PS5MCP_FTP_PORT` (2120). When it is not running, it is
  started once from Payload Manager's library (an `.elf` whose name starts with `zftpd`) unless
  `PS5MCP_FTP_AUTOSTART=0`. It cannot be stopped remotely: it stays up until the console reboots, and loading it
  again replaces the running copy.
- Folders are copied recursively. A file is skipped when the destination has the same size and is not older (a
  quick check like rsync's: `force` sends everything). A shorter destination that is not older is resumed (APPE
  up, REST down) only when its last bytes match the source at the same offset; otherwise it is sent again.
- Without zftpd, `push` uploads one file at a time through Web File Manager (no skipping or resuming), and `pull`
  takes single files only.

A remote path is absolute and names the destination itself; end it with "/" to copy into that folder instead.
"""

from __future__ import annotations

import ftplib
import os
import posixpath
import socket
import time
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from .probe_runner import Console

FTP_PORT = int(os.environ.get("PS5MCP_FTP_PORT", "2120"))
AUTOSTART = os.environ.get("PS5MCP_FTP_AUTOSTART", "1") != "0"
BLOCK = 1 << 20
TAIL = 64 << 10  # bytes compared before resuming
START_TIMEOUT = 15.0

Progress = Callable[[str], None]


@dataclass
class Stats:
    backend: str
    sent: int = 0
    resumed: int = 0
    skipped: int = 0
    bytes: int = 0
    started: float = 0.0

    def summary(self, verb: str, what: str) -> str:
        seconds = max(time.monotonic() - self.started, 1e-3)
        files = self.sent + self.resumed
        parts = [(f"{verb} {files} file{'s' * (files != 1)} ({self.bytes / 1e6:.1f} MB in {seconds:.1f} s, "
                  f"{self.bytes / 1e6 / seconds:.1f} MB/s)")]
        if self.resumed:
            parts.append(f"{self.resumed} resumed")
        if self.skipped:
            parts.append(f"{self.skipped} unchanged skipped")
        return f"{', '.join(parts)}: {what} via {self.backend}"


class _Meter:
    """Progress lines at most every 2 s."""

    def __init__(self, progress: Progress, name: str, total: int, done: int = 0):
        self.progress, self.name, self.total, self.done, self.shown = progress, name, total, done, 0.0

    def __call__(self, chunk: bytes) -> None:
        self.done += len(chunk)
        if time.monotonic() - self.shown > 2 or self.done >= self.total:
            self.shown = time.monotonic()
            self.progress(f"{self.name}: {self.done * 100 // max(self.total, 1)}% of {self.total >> 20} MB")


def push(host: str, local: str | Path, remote: str, progress: Progress = print, *, force: bool = False,
         port: int = FTP_PORT, autostart: bool = AUTOSTART, before_start: Callable[[], None] | None = None) -> str:
    """Copies `local` (a file or folder on this Mac) to `remote` on the console; returns a one-line summary."""
    source = Path(local).expanduser()
    if not source.exists():
        raise ValueError(f"{source} does not exist")
    target = _target(remote, source.name)
    stats = Stats("", started=time.monotonic())
    ftp = connect(host, port, autostart, progress, before_start)
    if ftp is None:
        stats.backend = "Web File Manager (zftpd not running)"
        _wfm_push(host, source, target, progress, stats)
        return stats.summary("sent", f"{source} -> {target}")
    stats.backend = f"zftpd :{port}"
    with ftp:
        if source.is_dir():
            _push_dir(ftp, source, target, progress, force, stats)
        else:
            _ensure_dir(ftp, posixpath.dirname(target))
            _push_file(ftp, source, target, _listing(ftp, posixpath.dirname(target)), progress, force, stats)
    return stats.summary("sent", f"{source} -> {target}")


def pull(host: str, remote: str, local: str | Path, progress: Progress = print, *, force: bool = False,
         port: int = FTP_PORT, autostart: bool = AUTOSTART, before_start: Callable[[], None] | None = None) -> str:
    """Copies `remote` (a file or folder on the console) to `local` on this Mac; returns a one-line summary."""
    remote = _absolute(remote).rstrip("/") or "/"
    dest = Path(local).expanduser()
    if dest.is_dir() or str(local).endswith("/"):
        dest = dest / (posixpath.basename(remote) or "root")
    stats = Stats("", started=time.monotonic())
    ftp = connect(host, port, autostart, progress, before_start)
    if ftp is None:
        stats.backend = "Web File Manager (zftpd not running)"
        _wfm_pull(host, remote, dest, progress, stats)
        return stats.summary("received", f"{remote} -> {dest}")
    stats.backend = f"zftpd :{port}"
    with ftp:
        facts = {"type": "dir"} if remote == "/" else _listing(ftp, posixpath.dirname(remote)).get(
            posixpath.basename(remote))
        if facts is None:
            raise ValueError(f"{remote} does not exist on the console")
        if facts["type"] == "dir":
            _pull_dir(ftp, remote, dest, progress, force, stats)
        else:
            dest.parent.mkdir(parents=True, exist_ok=True)
            _pull_file(ftp, remote, facts, dest, progress, force, stats)
    return stats.summary("received", f"{remote} -> {dest}")


def connect(host: str, port: int = FTP_PORT, autostart: bool = AUTOSTART, progress: Progress = print,
            before_start: Callable[[], None] | None = None) -> ftplib.FTP | None:
    """A logged-in FTP session with zftpd, starting it from Payload Manager first when allowed. None when zftpd is
    not running and cannot be started here (autostart off, or not in Payload Manager's library)."""
    if not _listening(host, port):
        if not autostart:
            return None
        path = _payload(host)
        if path is None:
            return None
        if before_start:
            before_start()
        progress(f"starting {path} (port {port})")
        Console(host).request(8084, "/loadpayload:" + urllib.parse.quote(path, safe="/"), method="GET")
        deadline = time.monotonic() + START_TIMEOUT
        while not _listening(host, port):
            if time.monotonic() > deadline:
                raise RuntimeError(f"started {path}, but nothing listens on port {port} after {START_TIMEOUT:.0f} s")
            time.sleep(0.5)
    ftp = ftplib.FTP(timeout=60)
    ftp.connect(host, port)
    ftp.login()  # zftpd accepts any user
    ftp.voidcmd("TYPE I")
    return ftp


def _listening(host: str, port: int) -> bool:
    try:
        socket.create_connection((host, port), timeout=2).close()
        return True
    except OSError:
        return False


def _payload(host: str) -> str | None:
    import json
    try:
        payloads = json.loads(Console(host).request(8084, "/list_payloads", method="GET"))["payloads"]
    except Exception:  # noqa: BLE001 - no Payload Manager means no autostart, not a failed transfer
        return None
    matches = sorted(p for p in payloads if posixpath.basename(p).lower().startswith("zftpd")
                     and p.lower().endswith(".elf"))
    return matches[-1] if matches else None


# -- FTP ----------------------------------------------------------------------------------------------------------

def _absolute(path: str) -> str:
    if not path.startswith("/"):
        raise ValueError(f"remote path must be absolute: {path!r}")
    return posixpath.normpath(path) + ("/" if path.endswith("/") and path != "/" else "")


def _target(remote: str, name: str) -> str:
    remote = _absolute(remote)
    return remote + name if remote.endswith("/") else remote


def _listing(ftp: ftplib.FTP, directory: str) -> dict[str, dict]:
    """Name -> MLSD facts (type, size, modify) for one folder; empty when it does not exist."""
    try:
        entries = list(ftp.mlsd(directory or "/"))
    except ftplib.error_perm:
        return {}
    return {name: facts for name, facts in entries if facts.get("type", "").lower() in ("file", "dir")}


def _ensure_dir(ftp: ftplib.FTP, directory: str) -> None:
    """Creates `directory` and its missing parents, starting from the deepest one that exists."""
    if directory in ("", "/"):
        return
    try:
        ftp.cwd(directory)
        return
    except ftplib.error_perm:
        pass
    _ensure_dir(ftp, posixpath.dirname(directory))
    try:
        ftp.mkd(directory)
    except ftplib.error_perm as exc:
        raise ValueError(f"cannot create the folder {directory} on the console: {exc}") from exc


def _modified(facts: dict) -> float:
    """MLSD `modify` (UTC, YYYYMMDDHHMMSS[.sss]) as a Unix time."""
    stamp = facts.get("modify", "")[:14]
    try:
        return datetime.strptime(stamp, "%Y%m%d%H%M%S").replace(tzinfo=UTC).timestamp()
    except ValueError:
        return 0.0


def _plan(size: int, mtime: float, have: int, have_mtime: float, force: bool) -> str:
    """send, resume or skip, given the source (size, mtime) and what the destination already holds."""
    if force or have_mtime < int(mtime):
        return "send"
    if have == size:
        return "skip"
    return "resume" if 0 < have < size else "send"


def _same_tail(ftp: ftplib.FTP, remote: str, local: Path, end: int) -> bool:
    """Whether the TAIL bytes before `end` are the same in both copies (both hold at least `end` bytes)."""
    start = max(0, end - TAIL)
    with local.open("rb") as f:
        f.seek(start)
        want = f.read(end - start)
    got = bytearray()
    ftp.voidcmd("TYPE I")  # mlsd() leaves the session in ASCII
    conn = ftp.transfercmd(f"RETR {remote}", rest=start or None)
    try:
        while len(got) < len(want) and (chunk := conn.recv(min(BLOCK, len(want) - len(got)))):
            got += chunk
    finally:
        conn.close()
    try:
        ftp.voidresp()  # 226, or 426 when the server saw the early close; zftpd has no ABOR
    except ftplib.Error:
        pass
    return bytes(got) == want


def _push_dir(ftp, source: Path, target: str, progress: Progress, force: bool, stats: Stats) -> None:
    _ensure_dir(ftp, target)
    for root, dirs, files in os.walk(source):
        dirs.sort()
        rel = Path(root).relative_to(source).as_posix()
        here = target if rel == "." else posixpath.join(target, rel)
        listing = _listing(ftp, here)
        for name in dirs:
            if name not in listing:
                ftp.mkd(posixpath.join(here, name))
            elif listing[name]["type"] != "dir":
                raise ValueError(f"{posixpath.join(here, name)} exists on the console and is not a folder")
        for name in sorted(files):
            _push_file(ftp, Path(root) / name, posixpath.join(here, name), listing, progress, force, stats)


def _push_file(ftp, source: Path, target: str, listing: dict, progress: Progress, force: bool, stats: Stats) -> None:
    st = source.stat()
    facts = listing.get(posixpath.basename(target))
    if facts and facts["type"] == "dir":
        raise ValueError(f"{target} is a folder on the console; end the remote path with / to copy into it")
    have = int(facts["size"]) if facts else 0
    action = _plan(st.st_size, st.st_mtime, have, _modified(facts) if facts else 0.0, force or not facts)
    if action == "skip":
        stats.skipped += 1
        return
    if action == "resume" and not _same_tail(ftp, target, source, have):
        action = "send"
    offset = have if action == "resume" else 0
    meter = _Meter(progress, target, st.st_size, offset)
    with source.open("rb") as f:
        f.seek(offset)
        # A resume appends (APPE, like curl -C -): the tail check above proved the console's bytes are a prefix.
        ftp.storbinary(f"{'APPE' if offset else 'STOR'} {target}", f, BLOCK, meter)
    if (size := ftp.size(target)) != st.st_size:
        raise RuntimeError(f"{target}: the console has {size} bytes after the upload, expected {st.st_size}")
    stats.bytes += st.st_size - offset
    if offset:
        stats.resumed += 1
    else:
        stats.sent += 1


def _pull_dir(ftp, remote: str, dest: Path, progress: Progress, force: bool, stats: Stats) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    for name, facts in sorted(_listing(ftp, remote).items()):
        if facts["type"] == "dir":
            _pull_dir(ftp, posixpath.join(remote, name), dest / name, progress, force, stats)
        else:
            _pull_file(ftp, posixpath.join(remote, name), facts, dest / name, progress, force, stats)


def _pull_file(ftp, remote: str, facts: dict, dest: Path, progress: Progress, force: bool, stats: Stats) -> None:
    size, mtime = int(facts.get("size", 0)), _modified(facts)
    have, have_mtime = (dest.stat().st_size, dest.stat().st_mtime) if dest.is_file() else (0, 0.0)
    action = _plan(size, mtime, have, have_mtime, force or not dest.is_file())
    if action == "skip":
        stats.skipped += 1
        return
    if action == "resume" and not _same_tail(ftp, remote, dest, have):
        action = "send"
    offset = have if action == "resume" else 0
    meter = _Meter(progress, remote, size, offset)
    with dest.open("r+b" if offset else "wb") as f:
        f.seek(offset)

        def write(chunk: bytes) -> None:
            f.write(chunk)
            meter(chunk)

        ftp.retrbinary(f"RETR {remote}", write, BLOCK, rest=offset or None)
        f.truncate()
    if (got := dest.stat().st_size) != size:
        raise RuntimeError(f"{dest}: received {got} bytes, the console lists {size}")
    if mtime:
        os.utime(dest, (mtime, mtime))  # so an unchanged file is skipped next time
    stats.bytes += size - offset
    if offset:
        stats.resumed += 1
    else:
        stats.sent += 1


# -- Web File Manager fallback ------------------------------------------------------------------------------------

def _wfm_push(host: str, source: Path, target: str, progress: Progress, stats: Stats) -> None:
    from .installer import _upload
    console = Console(host)
    files = [(source, target)] if source.is_file() else [
        (path, posixpath.join(target, path.relative_to(source).as_posix()))
        for path in sorted(source.rglob("*")) if path.is_file()]
    if source.is_dir():
        console.ensure_dir(target)
    for path, remote in files:
        console.ensure_dir(posixpath.dirname(remote))
        _upload(console, host, path, posixpath.dirname(remote), progress, 3600, name=posixpath.basename(remote))
        stats.sent += 1
        stats.bytes += path.stat().st_size


def _wfm_pull(host: str, remote: str, dest: Path, progress: Progress, stats: Stats) -> None:
    console = Console(host)
    parent, name = posixpath.split(remote)
    entry = next((e for e in console.listdir(parent or "/") if e["name"] == name), None)
    if entry is None:
        raise ValueError(f"{remote} does not exist on the console")
    if entry["type"] != "-":
        raise ValueError(f"{remote} is a folder: copying folders from the console needs zftpd")
    progress(f"downloading {remote} ({entry['size'] >> 20} MB) through Web File Manager")
    data = console.download(remote)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    stats.sent += 1
    stats.bytes += len(data)
