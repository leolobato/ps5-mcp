#!/usr/bin/env python3
"""Install build/PS5 MCP.app as /Applications/PS5 MCP.app and leave that as the only copy (`make install`)."""

import os
import plistlib
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from ps5mcp.hub import AppClient, AppNotRunning

ROOT = Path(__file__).resolve().parent.parent
BUILT = ROOT / "build/PS5 MCP.app"
INSTALLED = Path("/Applications/PS5 MCP.app")
STAGED = INSTALLED.with_name(".PS5 MCP.new.app")
RETIRED = INSTALLED.with_name(".PS5 MCP.old.app")
REASON = "make install: replacing the app (restarts it)"


def connect() -> AppClient | None:
    try:
        return AppClient(client="make-install")
    except AppNotRunning:
        return None


def wait_for_console(client: AppClient) -> None:
    """Agents may be mid-run: take a turn in the queue, so the restart interrupts nobody."""
    announced = False
    while not (lease := client.claim(REASON, idle_s=900))["granted"]:
        if not announced:
            print(f"Waiting for the console: {(lease.get('owner') or {}).get('reason', 'in use')}", flush=True)
            announced = True
        time.sleep(2)


def stop(client: AppClient) -> None:
    pid = client.status()["pid"]
    client.close()
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    sys.exit(f"The app (pid {pid}) did not quit; nothing was replaced. Quit it and run make install again.")


def swap() -> None:
    shutil.rmtree(RETIRED, ignore_errors=True)
    if INSTALLED.exists():
        INSTALLED.rename(RETIRED)
    STAGED.rename(INSTALLED)
    shutil.rmtree(RETIRED, ignore_errors=True)


def report(build: str) -> None:
    """The window also says when the link is blocked; this is for whoever ran make."""
    deadline = time.monotonic() + 15
    status = None
    while time.monotonic() < deadline:
        client = connect()
        if client:
            status = client.status()
            client.close()
            if status["pad"]["connected"]:  # a first connect can fail and then succeed, so keep looking until the deadline
                break
        time.sleep(0.5)
    if not status:
        sys.exit(f"Installed build {build}, but the app did not answer. See {INSTALLED}.")
    print(f"Installed build {build} at {INSTALLED} (running build {status.get('build', '?')}).")
    if status["pad"].get("unreachable"):
        print("The console is unreachable. If it is on, macOS lost the Local Network permission: turn each PS5 MCP entry "
              "in System Settings > Privacy & Security > Local Network off and on again.")


def main() -> None:
    if not BUILT.exists():
        sys.exit(f"{BUILT} is missing; run make app.")
    with (BUILT / "Contents/Info.plist").open("rb") as info:
        build = plistlib.load(info)["CFBundleVersion"]
    shutil.rmtree(STAGED, ignore_errors=True)
    subprocess.run(["ditto", str(BUILT), str(STAGED)], check=True)
    if client := connect():
        wait_for_console(client)
        stop(client)
    swap()
    # An MCP server can start the old copy while it is being replaced.
    if client := connect():
        stop(client)
    subprocess.run(["open", str(INSTALLED)], check=True)
    report(build)
    shutil.rmtree(BUILT)
    shutil.rmtree(ROOT / "build/DerivedData", ignore_errors=True)


if __name__ == "__main__":
    main()
