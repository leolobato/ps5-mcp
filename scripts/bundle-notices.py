#!/usr/bin/env python3
"""Stage exact dependency notices alongside the app's static libraries."""
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / ".deps/remoteplay/sources"
CHIAKI = ROOT / "third-party/chiaki-ng"


def main():
    destination = ROOT / "build/bundle/Licenses"
    destination.mkdir(parents=True, exist_ok=True)
    notices = {
        "PS5-MCP-AGPL.txt": ROOT / "LICENSE",
        "PS5-MCP-MIT-NOTICE.txt": ROOT / "third-party/PS5-MCP-MIT-NOTICE.txt",
        "Dependencies.md": ROOT / "third-party/README.md",
        "Chiaki-ng.txt": CHIAKI / "COPYING",
        "curl.txt": CHIAKI / "third-party/curl/COPYING",
        "nanopb.txt": CHIAKI / "third-party/nanopb/LICENSE.txt",
        "Jerasure.txt": CHIAKI / "third-party/jerasure/COPYING",
        "GF-Complete.txt": CHIAKI / "third-party/gf-complete/COPYING",
        "OpenSSL.txt": SOURCES / "openssl/LICENSE.txt",
        "Opus.txt": SOURCES / "opus/COPYING",
        "json-c.txt": SOURCES / "json-c/COPYING",
        "miniupnpc.txt": SOURCES / "miniupnpc/LICENSE",
        "libevent.txt": SOURCES / "libevent/LICENSE",
        "Account-Tools-GPL.txt": ROOT / "third-party/account-tools/LICENSE",
        "Account-Setup-Notice.md": ROOT / "payload/remoteplay-setup/NOTICE.md",
        "Account-Tools-Source.json": ROOT / "third-party/account-tools/SOURCE.json",
    }
    for name, source in notices.items():
        shutil.copyfile(source, destination / name)
    shutil.copyfile(ROOT / "toolchain.lock.json", destination / "toolchain.lock.json")


if __name__ == "__main__":
    main()
