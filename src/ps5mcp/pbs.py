"""The PBS payload (seregonwar/PBS-Payload, GPL-3.0), fetched from its upstream release on request.

PS5 MCP does not carry PBS: `get-pbs` downloads one pinned release from GitHub, checks its SHA256, and installs it
into Payload Manager's library like any other `.elf`. See third-party/pbs-payload/README.md.
"""

from __future__ import annotations

import hashlib
import os
import tempfile
import urllib.request
from pathlib import Path

from . import capture

VERSION = "0.4.0-beta.6"
NAME = f"PBS-Payload-{VERSION}-ps5.elf"
URL = f"https://github.com/seregonwar/PBS-Payload/releases/download/v{VERSION}/{NAME}"
SHA256 = "5f7bde34491b80f31b08095790e20f405de82b4646aa4349a69cfc59d5e4772f"
MAX_BYTES = 16 << 20


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fetch(cache: Path | None = None, url: str = URL, sha256: str = SHA256, timeout: float = 60) -> Path:
    """The pinned PBS ELF in `cache`, downloaded first unless a copy with the right hash is already there."""
    cache = Path(cache or capture.state_dir() / "pbs")
    target = cache / NAME
    if target.is_file() and _sha256(target) == sha256:
        return target
    cache.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=timeout) as response:  # noqa: S310 - a fixed https URL, hash-checked
        data = response.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise RuntimeError(f"{NAME} from {url} is larger than {MAX_BYTES >> 20} MB")
    digest = hashlib.sha256(data).hexdigest()
    if digest != sha256:
        raise RuntimeError(f"{NAME} from {url} has SHA256 {digest}, expected {sha256}; nothing was installed")
    fd, temporary = tempfile.mkstemp(dir=cache, prefix=".download-")
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        os.replace(temporary, target)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
    return target
