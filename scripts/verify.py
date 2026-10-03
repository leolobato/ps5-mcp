#!/usr/bin/env python3
"""Check cross-built payload formats and record their hashes; never runs target binaries."""
import hashlib
import json
import os
import platform
import shutil
import subprocess
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAYLOADS = ("padd.elf",)


def output(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def main():
    lock = json.loads((ROOT / "toolchain.lock.json").read_text())
    sdk = Path(os.environ["PS5_PAYLOAD_SDK"])
    marker = sdk / ".ps5mcp-sha256"
    if not marker.exists() or marker.read_text().strip() != lock["ps5_payload_sdk"]["sha256"]:
        raise SystemExit("SDK pin not verified; run make bootstrap")
    llvm = output(os.environ["LLVM_CONFIG"], "--version")
    if llvm != lock["llvm_version"]:
        raise SystemExit(f"Expected LLVM {lock['llvm_version']}, found {llvm}")
    if not shutil.which("llvm-readobj"):
        raise SystemExit("Missing llvm-readobj")
    artifacts = {}
    for name in PAYLOADS:
        path = ROOT / "build" / name
        headers = output("llvm-readobj", "--file-headers", str(path))
        if "Format: elf64-x86-64" not in headers or "EM_X86_64" not in headers:
            raise SystemExit(f"Unexpected format for {name}:\n{headers}")
        artifacts[name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                           "bytes": path.stat().st_size, "format": "elf64-x86-64"}
        print(f"Verified {name}: {artifacts[name]['sha256']}")
    report = {"recorded_at": datetime.now(UTC).isoformat(), "host": platform.platform(),
              "sdk": lock["ps5_payload_sdk"], "llvm": llvm, "hardware_validated": False,
              "artifacts": artifacts}
    (ROOT / "build/toolchain-report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
