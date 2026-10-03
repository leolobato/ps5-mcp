"""Explicit console steps for the long-running padd payload, each archived under results/<run-id>-padd/.

- start:   snapshot, verified upload, ONE launch, wait for `pad_added`, check HELLO.
- soak:    stream harmless input for N minutes, then check for stuck buttons.
- killtest: a client holds buttons and is SIGKILLed; padd must release them.
- stop:    SHUTDOWN, wait for `exit_requested`, archive the full log.
Nothing here relaunches padd on its own.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.parse
from datetime import UTC, datetime
from pathlib import Path

from . import capture
from . import protocol as p
from .client import PadController, PadError, PadLink
from .probe_runner import ROOT, Console, _git, _snapshot, digest

LOG_DIR = "/data/ps5-mcp/logs"
SOURCES = ("payload/padd.c", "payload/smp.c", "payload/smp.h", "payload/protocol.h", "payload/system.h",
           "payload/system_ps5.c")


def current_run_file() -> Path:
    return capture.state_dir() / "padd-run"


def current_run() -> Path:
    try:
        return Path(current_run_file().read_text().strip())
    except FileNotFoundError:
        raise SystemExit("No padd run recorded; use `ps5mcp padd start` first") from None


def classify(raw: bytes) -> tuple[str, list[dict]]:
    """System libraries print their own diagnostics to padd's stdout; those lines become `foreign` records."""
    records = []
    lines = raw.splitlines()
    for index, line in enumerate(lines):
        if not line.strip():
            continue
        if not line.startswith(b"{"):
            records.append({"foreign": line.decode(errors="replace")})
            continue
        try:
            records.append(json.loads(line))
        except ValueError:
            if index == len(lines) - 1:
                return "incomplete", records  # torn final line: still being written
            records.append({"foreign": line.decode(errors="replace")})
    events = [r.get("event") for r in records]
    if "exit_requested" not in events:
        return "running" if "pad_added" in events else "incomplete", records
    exit_code = [r for r in records if r.get("event") == "exit_requested"][-1].get("code")
    added = [r for r in records if r.get("event") == "pad_added"]
    if exit_code != 0 or not added or not added[0].get("ok") or "report_failed" in events:
        return "failed", records
    return "passed", records


def _load(run: Path) -> dict:
    return json.loads((run / "run.json").read_text())


def _save(run: Path, evidence: dict) -> None:
    evidence["updated_at"] = datetime.now(UTC).isoformat()
    (run / "run.json").write_text(json.dumps(evidence, indent=2) + "\n")


def _port_open(host: str, port: int = p.PORT) -> bool:
    try:
        with socket.create_connection((host, port), timeout=2):
            return True
    except OSError:
        return False


def collect(run: Path | None = None) -> dict:
    run = run or current_run()
    evidence = _load(run)
    console = Console(evidence["console"])
    raw = console.download(evidence["console_log_path"])
    (run / "output.jsonl").write_bytes(raw)
    evidence["output_sha256"] = digest(raw)
    evidence["status"], records = classify(raw)
    evidence["last_events"] = records[-8:]
    _save(run, evidence)
    return evidence


def start(host: str, firmware: str | None, timeout: float = 20) -> int:
    elf = ROOT / "build/padd.elf"
    raw = elf.read_bytes()
    report = json.loads((ROOT / "build/toolchain-report.json").read_text())
    if report["artifacts"].get(elf.name, {}).get("sha256") != digest(raw):
        raise SystemExit("Build report is stale; run make first")
    if _port_open(host):
        raise SystemExit(f"Something already listens on {host}:{p.PORT}; padd is probably running. "
                         "Use `ps5mcp padd status` or `ps5mcp padd stop`.")
    run_id = datetime.now(UTC).strftime("%Y%m%dT%H%M%S.%fZ") + "-padd"
    run = ROOT / "results" / run_id
    (run / "source").mkdir(parents=True)
    (run / "toolchain-report.json").write_text(json.dumps(report, indent=2) + "\n")
    for source in SOURCES:
        (run / "source" / Path(source).name).write_bytes((ROOT / source).read_bytes())
    evidence = {"run_id": run_id, "console": host, "firmware_user_reported": firmware, "elf_sha256": digest(raw),
                "git_commit": _git("rev-parse", "HEAD"), "git_status_before_run": _git("status", "--porcelain"),
                "status": "incomplete", "launch_requested": False,
                "limitations": "Console model and kernel patch state are not verified."}
    current_run_file().write_text(f"{run}\n")
    console = Console(host)
    try:
        evidence["loader_version"] = console.request(8084, "/version", method="GET").decode().strip()
        console.ensure_dir(LOG_DIR)
        _snapshot(run, "before", evidence)
        before = {e["name"] for e in console.listdir(LOG_DIR)}
        filename = "ps5mcp-padd.elf"
        console.request(8084, "/manage:upload", {"filename": filename}, raw, {"Content-Type": "application/octet-stream"})
        paths = json.loads(console.request(8084, "/list_payloads", method="GET"))["payloads"]
        matches = [path for path in paths if path.endswith("/" + filename)]
        if len(matches) != 1:
            raise RuntimeError(f"Ambiguous uploaded payload paths: {matches}")
        evidence["console_payload_path"] = matches[0]
        if console.download(matches[0]) != raw:
            raise RuntimeError("Uploaded ELF readback mismatch")
        evidence["upload_verified"] = True
        evidence["launch_requested"] = True
        evidence["launched_at"] = datetime.now(UTC).isoformat()
        console.request(8084, "/loadpayload:" + urllib.parse.quote(matches[0], safe="/"), method="GET")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            logs = [e for e in console.listdir(LOG_DIR) if e["name"] not in before and e["name"].startswith("padd-")]
            if len(logs) > 1:
                raise RuntimeError("Multiple new padd logs; cannot attribute run")
            if logs:
                evidence["console_log_path"] = logs[0]["path"]
                output = console.download(logs[0]["path"])
                (run / "output.jsonl").write_bytes(output)
                evidence["status"], _ = classify(output)
                if evidence["status"] != "incomplete":
                    break
            time.sleep(0.5)
        else:
            evidence["error"] = "Timed out waiting for pad_added; no automatic relaunch"
        if evidence["status"] == "running":
            link = PadLink(host)
            evidence["hello"] = link.hello.__dict__
            evidence["auto_assign"] = auto_assign(link, run)
            link.close()
    except Exception as exc:  # noqa: BLE001 - any failure is recorded as an incomplete run
        evidence["status"] = "incomplete"
        evidence["error"] = str(exc)
    finally:
        _save(run, evidence)
    print(f"{evidence['status']}: {run.relative_to(ROOT)}")
    if evidence.get("error"):
        print(evidence["error"])
    if evidence.get("hello"):
        print(f"hello: {evidence['hello']}")
    return 0 if evidence["status"] == "running" else 1


def auto_assign(link: PadLink, run: Path | None = None, timeout: float = 6.0) -> bool:
    """Answer the assignment dialog for the new pad if (and only if) it is on screen."""
    from . import assign

    def press_cross() -> None:
        link.send_state(p.PadState(buttons=p.BUTTONS["cross"]), wait=True)
        time.sleep(0.1)
        link.send_state(p.PadState(), wait=True)

    answered = assign.assign_if_asked(assign.capture_frame(), press_cross, timeout=timeout, log=print)
    if answered and run:
        _snapshot(run, "after-auto-assign", {})
    return answered


def status(host: str) -> int:
    try:
        link = PadLink(host)
    except (OSError, PadError) as exc:
        print(f"padd unreachable at {host}:{p.PORT}: {exc}")
        return 1
    pong = link.ping()
    link.close()
    print(json.dumps({"hello": link.hello.__dict__, "pong": pong.__dict__}, indent=2))
    return 0


def _frame_diff(a: Path, b: Path) -> float:
    """Mean absolute luma difference 0..255 between two snapshots."""
    def gray(path):
        return subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path), "-vf",
                               "scale=160:90,format=gray", "-f", "rawvideo", "-"],
                              capture_output=True, check=True).stdout
    x, y = gray(a), gray(b)
    return sum(abs(i - j) for i, j in zip(x, y, strict=True)) / len(x)


def soak(host: str, minutes: float, period: float = 2.0) -> int:
    """Alternate D-pad right/left taps (net zero movement) while streaming continuously."""
    run = current_run()
    evidence = _load(run)
    controller = PadController(host, keepalive=0.05)
    result: dict = {"started_at": datetime.now(UTC).isoformat(), "minutes": minutes, "pattern":
                    "every period: right 80 ms, then left 80 ms half a period later"}
    taps = 0
    try:
        controller.link(wait=5)
        before = controller.link().ping()
        deadline = time.monotonic() + minutes * 60
        while time.monotonic() < deadline:
            for button in ("right", "left"):
                controller.set_agent(p.PadState(buttons=p.BUTTONS[button]))
                time.sleep(0.08)
                controller.set_agent(p.PadState())
                taps += 1
                time.sleep(period / 2 - 0.08)
        controller.release_all()
        time.sleep(0.5)
        link = controller.link()
        after = link.ping()
        result.update(taps=taps, reconnects=controller.status().reconnects, states_sent=controller.states_sent,
                      final_state_neutral=link.get_state().is_neutral(),
                      reports_during=after.reports_sent - before.reports_sent,
                      report_failures=after.report_failures, neutral_events_during=after.neutral_events
                      - before.neutral_events, pong_after=after.__dict__)
    except PadError as exc:
        result["error"] = str(exc)
    finally:
        controller.close()
    capture.snapshot(run / "soak-end-1.png")
    time.sleep(2)
    capture.snapshot(run / "soak-end-2.png")
    result["idle_frame_diff"] = round(_frame_diff(run / "soak-end-1.png", run / "soak-end-2.png"), 2)
    result["passed"] = bool(not result.get("error") and result.get("final_state_neutral") and
                            result.get("reconnects") == 0 and result.get("report_failures") == 0 and
                            result["idle_frame_diff"] < 2.0)
    result["finished_at"] = datetime.now(UTC).isoformat()
    evidence["soak"] = result
    _save(run, evidence)
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


_HOLDER = """
import sys, time
from ps5mcp.client import PadLink
from ps5mcp.protocol import PadState, BUTTONS
link = PadLink(sys.argv[1])
state = PadState(buttons=BUTTONS["l2"] | BUTTONS["r2"], l2=255, r2=255)
print("holding", flush=True)
while True:
    link.send_state(state)
    time.sleep(0.05)
"""


def killtest(host: str) -> int:
    """SIGKILL a client mid-hold; padd must drop to neutral by itself (triggers only: no UI effect)."""
    run = current_run()
    evidence = _load(run)
    result: dict = {"held": "L2+R2 fully pressed (no home-screen action)"}
    holder = subprocess.Popen([sys.executable, "-c", _HOLDER, host], stdout=subprocess.PIPE, text=True)
    try:
        if holder.stdout.readline().strip() != "holding":
            raise PadError("holder did not start")
        time.sleep(1.0)
        os.kill(holder.pid, signal.SIGKILL)
        holder.wait(5)
        result["killed_at"] = datetime.now(UTC).isoformat()
        link = None
        deadline = time.monotonic() + 5
        while link is None:
            try:
                link = PadLink(host)
            except PadError:  # busy until padd notices the dead socket
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.1)
        state = link.get_state()
        pong = link.ping()
        link.close()
        result.update(state_after=state.__dict__ | {"touch": None}, released=state.is_neutral(),
                      neutral_events=pong.neutral_events)
    except PadError as exc:
        result["error"] = str(exc)
        result["released"] = False
    finally:
        if holder.poll() is None:
            holder.kill()
    result["passed"] = bool(result.get("released"))
    evidence["killtest"] = result
    _save(run, evidence)
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


def stop(host: str, timeout: float = 10) -> int:
    run = current_run()
    evidence = _load(run)
    try:
        link = PadLink(host)
        link.shutdown()
        link.close()
        evidence["shutdown_acked"] = True
    except (OSError, PadError) as exc:
        evidence["shutdown_error"] = str(exc)
    _save(run, evidence)
    deadline = time.monotonic() + timeout
    while True:
        evidence = collect(run)
        if evidence["status"] != "running" or time.monotonic() > deadline:
            break
        time.sleep(0.5)
    evidence["port_closed_after"] = not _port_open(host)
    _snapshot(run, "after", evidence)
    processes = json.loads(Console(host).request(8084, "/processes_list", method="GET"))["processes"]
    (run / "processes-after.json").write_text(json.dumps(processes, indent=2) + "\n")
    evidence["remaining_padd_processes"] = [proc for proc in processes if "padd" in proc["name"].lower()]
    _save(run, evidence)
    print(f"{evidence['status']}: {run.relative_to(ROOT)}")
    for record in evidence.get("last_events", []):
        print(json.dumps(record))
    return 0 if evidence["status"] == "passed" else 1
