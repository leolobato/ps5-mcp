"""Explicitly authorised, capture-only hardware validation; no console-service calls.

Run manually with --device after closing other physical capture viewers. Results and
screenshots stay in the specified output directory. This never loads kernel modules.
"""
from __future__ import annotations

import argparse
import asyncio
import concurrent.futures
import contextlib
import io
import itertools
import json
import os
import signal
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from PIL import Image

from ps5mcp.capture import CaptureError
from ps5mcp.hub import AppClient
from ps5mcp.linux.backend import LinuxHub


def distribution(values):
    values = sorted(values)
    if not values:
        return {}
    return {"median": statistics.median(values), "p95": values[int((len(values) - 1) * .95)],
            "max": max(values), "samples": len(values)}


def process_usage(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()
    return {"ticks": int(fields[11]) + int(fields[12]),
            "rss_mib": int(Path(f"/proc/{pid}/statm").read_text().split()[1]) * os.sysconf("SC_PAGE_SIZE") / 2**20}


def wait_status(backend, predicate, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = backend.status()
        if status and predicate(status):
            return status
        time.sleep(.02)
    raise RuntimeError(f"Timed out waiting for capture state: {backend.status()}")


def measure(backend, seconds):
    client = AppClient(backend.socket, client="capture-measurement")
    try:
        first = client.status()
        pids = {"hub": first["pid"], "ffmpeg": first["ffmpeg_pid"]}
        before = {key: process_usage(pid) for key, pid in pids.items()}
        ages, cadence, requests = [], [], []
        prior = first
        start = time.monotonic()
        while time.monotonic() - start < seconds:
            began = time.monotonic()
            current = client.status()
            ended = time.monotonic()
            assert current["capture_error"] is None, current
            assert current["ffmpeg_pid"] == pids["ffmpeg"], current
            assert not current["pad"]["connected"], "Console access must remain disabled"
            ages.append((ended - current["frame_timestamp"]) * 1000)
            requests.append((ended - began) * 1000)
            if current["frame_sequence"] == prior["frame_sequence"] + 1:
                cadence.append((current["frame_timestamp"] - prior["frame_timestamp"]) * 1000)
            prior = current
            time.sleep(max(0, .02 - (time.monotonic() - began)))
        elapsed = time.monotonic() - start
        final = client.status()
        resources = {}
        for key, pid in pids.items():
            after = process_usage(pid)
            resources[key] = {"pid": pid, "cpu_percent_one_core":
                              (after["ticks"] - before[key]["ticks"]) / os.sysconf("SC_CLK_TCK") / elapsed * 100,
                              "rss_mib": after["rss_mib"]}
        return {"seconds": elapsed, "frames": final["frame_sequence"] - first["frame_sequence"],
                "fps": (final["frame_sequence"] - first["frame_sequence"]) / elapsed,
                "frame_age_at_client_ms": distribution(ages), "observed_adjacent_frame_interval_ms": distribution(cadence),
                "status_rpc_ms": distribution(requests), "resources": resources,
                "capture_starts": final["capture_starts"]}
    finally:
        client.close()


def viewer(url, seconds):
    ages, sequences = [], []
    began = time.monotonic()
    with urllib.request.urlopen(url + "stream.mjpg", timeout=5) as response:
        while time.monotonic() - began < seconds:
            if response.readline().strip() != b"--ps5frame":
                raise RuntimeError("Missing multipart boundary")
            headers = {}
            while (line := response.readline().strip()):
                key, value = line.decode().split(":", 1)
                headers[key] = value.strip()
            data = response.read(int(headers["Content-Length"]))
            assert data.startswith(b"\xff\xd8") and data.endswith(b"\xff\xd9")
            assert response.read(2) == b"\r\n"
            if not sequences:
                with Image.open(io.BytesIO(data)) as image:
                    assert image.size == (1920, 1080)
            sequences.append(int(headers["X-Frame-Sequence"]))
            ages.append((time.monotonic() - float(headers["X-Frame-Timestamp"])) * 1000)
    return {"frames_received": len(sequences), "skipped_cache_frames": sum(max(0, b-a-1)
            for a, b in itertools.pairwise(sequences)), "receive_age_ms": distribution(ages)}


async def workload(backend, env, seconds):
    snapshots = []
    async with contextlib.AsyncExitStack() as stack:
        clients = []
        for _ in range(3):
            read, write = await stack.enter_async_context(stdio_client(StdioServerParameters(
                command=sys.executable, args=["-m", "ps5mcp.server"], env=env)))
            client = await stack.enter_async_context(ClientSession(read, write, read_timeout_seconds=20))
            await client.initialize()
            clients.append(client)

        async def snapshots_from(client):
            elapsed = []
            for _ in range(15):
                began = time.monotonic()
                reply = await client.call_tool("snapshot", {"max_width": 1280})
                assert reply.content[0].type == "image", reply
                elapsed.append((time.monotonic() - began) * 1000)
                await asyncio.sleep(.4)
            snapshots.extend(elapsed)

        url = backend.status()["viewer_url"]
        with concurrent.futures.ThreadPoolExecutor() as pool:
            viewers = [pool.submit(viewer, url, seconds) for _ in range(3)]
            measurement, *_ = await asyncio.gather(asyncio.to_thread(measure, backend, seconds),
                                                    *(snapshots_from(client) for client in clients))
            measurement["viewers"] = [future.result() for future in viewers]
        measurement["mcp_snapshot_rpc_ms"] = distribution(snapshots)
        measurement["mcp_clients"] = len(clients)
        return measurement


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=12)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    # Never inherit console opt-in or service endpoints from the user's shell.
    env = os.environ.copy()
    for key in ("PS5_HOST", "PS5MCP_STREAM_PORT", "PS5MCP_VIEW", "PS5MCP_VIDEO_FORMAT", "PS5MCP_VIDEO_SIZE",
                "PS5MCP_VIDEO_FPS", "PS5MCP_VIDEO", "PS5MCP_VIDEO_STALE_S", "PS5MCP_VIEWER_PORT"):
        env.pop(key, None)
        os.environ.pop(key, None)
    env.update(PS5MCP_ALLOW_CONSOLE="0", PS5MCP_BACKEND="linux", PS5MCP_STATE=str(args.output / "state"))
    os.environ.update(env)
    backend = LinuxHub(args.output / "state")
    report = {"device": args.device, "mode": "MJPEG 1920x1080 60 FPS", "console_enabled": False}
    try:
        backend.start(video=args.device, video_format="mjpeg", video_size="1920x1080", video_fps="60")
        initial = wait_status(backend, lambda s: s["capture_error"] is None)
        assert not initial["pad"]["connected"]
        data, metadata = backend.read_frame()
        (args.output / "physical-snapshot.jpg").write_bytes(data)
        with Image.open(io.BytesIO(data)) as image:
            assert image.size == (1920, 1080)
        report["snapshot"] = metadata
        report["initial_status"] = initial
        result = subprocess.run([sys.executable, "-m", "ps5mcp.cli", "view"], env=env,
                                capture_output=True, text=True, timeout=10, check=True)
        assert initial["viewer_url"] in result.stdout
        report["ps5mcp_view"] = result.stdout.strip()
        print("Measuring baseline capture", flush=True)
        report["baseline"] = measure(backend, args.seconds)
        print("Measuring three MCP clients and three viewers", flush=True)
        report["concurrent"] = asyncio.run(workload(backend, env, args.seconds))
        current = backend.status()
        old_pid = current["ffmpeg_pid"]
        began = time.monotonic()
        os.kill(old_pid, signal.SIGSTOP)  # Only this test's capture child; no USB or console resets.
        try:
            stale = wait_status(backend, lambda s: bool(s["capture_error"]), timeout=6)
            report["stale_detection_s"] = time.monotonic() - began
            report["stale_error"] = stale["capture_error"]
            try:
                backend.read_frame()
                raise AssertionError("Stale screenshot was accepted")
            except CaptureError:
                pass
            try:
                urllib.request.urlopen(initial["viewer_url"] + "snapshot.jpg", timeout=3)
                raise AssertionError("Stale HTTP snapshot was accepted")
            except urllib.error.HTTPError as exc:
                assert exc.code == 503
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.kill(old_pid, signal.SIGKILL)
        recovered = wait_status(backend, lambda s: s["capture_error"] is None and
                                s["ffmpeg_pid"] != old_pid and s["capture_starts"] > current["capture_starts"])
        report["fresh_recovery_from_pause_s"] = time.monotonic() - began
        report["recovered_status"] = recovered
        assert recovered["frame_timestamp"] > current["frame_timestamp"]
        report["post_recovery_viewer"] = viewer(initial["viewer_url"], 1)
        other = LinuxHub(args.output / "conflicting-state")
        try:
            other.start(video=args.device, video_format="mjpeg", video_size="1920x1080", video_fps="60")
            raise AssertionError("A second physical owner was accepted")
        except CaptureError as exc:
            assert "already owned" in str(exc), exc
            report["second_owner_refused"] = True
    finally:
        report["shutdown"] = backend.stop()
        report["hub_socket_gone"] = not backend.socket.exists()
        (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
