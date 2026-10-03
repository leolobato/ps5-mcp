#!/usr/bin/env python3
"""Install the pinned SDK locally; host compilers are installed with Homebrew."""
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    lock = json.loads((ROOT / "toolchain.lock.json").read_text())
    sdk = lock["ps5_payload_sdk"]
    deps = ROOT / ".deps"
    downloads = deps / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / f"ps5-payload-sdk-{sdk['version']}.zip"
    if not archive.exists():
        partial = archive.with_suffix(".partial")
        subprocess.run(["curl", "-fL", "--retry", "3", "-o", str(partial), sdk["url"]], check=True)
        partial.replace(archive)
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != sdk["sha256"]:
        raise SystemExit(f"SDK checksum mismatch: {archive}; remove it and retry")
    destination = deps / "ps5-payload-sdk"
    marker = destination / ".ps5mcp-sha256"
    if destination.exists():
        if not marker.exists() or marker.read_text().strip() != actual:
            raise SystemExit(f"Unmanaged/different SDK at {destination}; move it aside and retry")
    else:
        with tempfile.TemporaryDirectory(dir=deps) as staging:
            # ditto/unzip preserves SDK wrapper executable bits and symlinks.
            subprocess.run(["unzip", "-q", str(archive), "-d", staging], check=True)
            shutil.move(str(Path(staging) / "ps5-payload-sdk"), destination)
        marker.write_text(actual + "\n")
    print(f"SDK {sdk['version']} verified: {destination}")
    print("Next: make check")


if __name__ == "__main__":
    main()
