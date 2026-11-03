"""The PBS video source in the real app, against a fake PBS HTTP service on localhost."""

from __future__ import annotations

import http.server
import json
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

import pytest
from PIL import Image

from ps5mcp import capture
from ps5mcp.hub import AppClient

from .test_app import APP, App
from .test_padd_host import BINARY, Padd

ROOT = Path(__file__).resolve().parents[1]

pytestmark = [
    pytest.mark.skipif(not (BINARY.exists() and APP.exists()), reason="run make (padd-host and the app)"),
    pytest.mark.skipif(not shutil.which("ffmpeg"), reason="ffmpeg generates the H.264 frames"),
]


def _has_pbs() -> bool:
    if not APP.exists():
        return False
    return "pbs" in subprocess.run([str(APP), "--features"], capture_output=True, text=True, timeout=10,
                                check=False).stdout


# Only `make app PBS=1` has the source; PBSSource.swift itself is compiled and tested below either way.
needs_pbs_build = pytest.mark.skipif(not _has_pbs(), reason="the app was built without PBS (make app PBS=1)")


def blue_frame(tmp_path) -> tuple[bytes, bytes, bytes]:
    """One IDR access unit in Annex B, with its SPS and PPS split out as PBS's /config.json carries them."""
    path = tmp_path / "blue.h264"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=1920x1080:r=60", "-frames:v", "1",
                    "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-pix_fmt", "yuv420p",
                    "-x264-params", "keyint=1:repeat-headers=1", "-f", "h264", str(path)], check=True)
    data = path.read_bytes()
    units = [unit.lstrip(b"\0") for unit in data.split(b"\0\0\1") if unit.strip(b"\0")]
    sps = next(unit.rstrip(b"\0") for unit in units if unit[0] & 0x1f == 7)
    pps = next(unit.rstrip(b"\0") for unit in units if unit[0] & 0x1f == 8)
    picture = b"".join(b"\0\0\0\1" + unit.rstrip(b"\0") for unit in units if unit[0] & 0x1f == 5)
    return sps, pps, picture


class FakePBS:
    def __init__(self, sps: bytes, pps: bytes, picture: bytes, port: int = 0):
        self.sps, self.pps, self.picture = sps, pps, picture
        self.requests: list[str] = []
        self.first: list[bytes] = []  # raw /frames packets sent before the good picture
        self.library: list[str] = []  # what /list_payloads reports, as Payload Manager does
        self.audio_packets = 0
        self.audio_down = False  # /audio ends and refuses, while /frames goes on
        self.stopping = threading.Event()
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                pass

            def begin(self, kind: str):
                self.send_response(200)
                self.send_header("Content-Type", kind)
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True

            def do_POST(self):
                fake.requests.append(f"POST {self.path}")
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True

            def do_GET(self):
                fake.requests.append(f"GET {self.path}")
                try:
                    if self.path == "/config.json":
                        body = json.dumps({"platform": "PS5", "width": 1920, "height": 1080, "fps": 60,
                                           "sps": fake.sps.hex(), "pps": fake.pps.hex(),
                                           "audio": {"codec": "pcm_f32le", "channels": 2, "rate": 48000, "bits": 32}})
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(body)))
                        self.send_header("Connection", "close")
                        self.end_headers()
                        self.wfile.write(body.encode())
                        self.close_connection = True
                    elif self.path == "/list_payloads" or self.path.startswith("/loadpayload:"):
                        body = json.dumps({"payloads": fake.library}) if self.path == "/list_payloads" else "ok"
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(body)))
                        self.send_header("Connection", "close")
                        self.end_headers()
                        self.wfile.write(body.encode())
                        self.close_connection = True
                    elif self.path == "/frames":
                        self.begin("application/octet-stream")
                        while fake.first:
                            self.wfile.write(fake.first.pop(0))
                        while not fake.stopping.is_set():
                            self.wfile.write(struct.pack(">II", len(fake.picture), 0) + fake.picture)
                            self.wfile.flush()
                            time.sleep(1 / 30)
                    elif self.path == "/audio" and fake.audio_down:
                        self.send_error(404)
                    elif self.path == "/audio":
                        self.begin("application/octet-stream")
                        pcm = struct.pack("<ff", 0.25, -0.25) * 1024
                        while not fake.stopping.is_set() and not fake.audio_down:
                            self.wfile.write(struct.pack(">II", len(pcm), 0) + pcm)
                            self.wfile.flush()
                            fake.audio_packets += 1
                            time.sleep(1024 / 48000)
                    else:
                        self.send_error(404)
                except OSError:
                    self.close_connection = True

        http.server.ThreadingHTTPServer.allow_reuse_address = True
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.stopping.set()
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def pbs(tmp_path):
    fake = FakePBS(*blue_frame(tmp_path))
    yield fake
    fake.stop()


@pytest.fixture
def padd(tmp_path):
    daemon = Padd(tmp_path)
    yield daemon
    daemon.stop()


def wait(check, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("condition not met in time")


def snapshot_rgb(hub: App) -> tuple[int, int, int]:
    path = wait(lambda: (hub.root / "latest.jpg") if (hub.root / "latest.jpg").exists() else None)
    with Image.open(path) as image:
        return image.convert("RGB").resize((1, 1)).getpixel((0, 0))


def start(padd, port: int) -> App:
    return App(padd, None, "--video", "pbs", "--pbs-port", str(port))


@needs_pbs_build
def test_streams_video_and_audio_and_reports_status(padd, pbs):
    hub = start(padd, pbs.port)
    try:
        status = hub.client().status()
        assert status["source"] == "pbs" and status["frames"] > 0
        red, green, blue = snapshot_rgb(hub)
        assert blue > 150 and red < 80 and green < 80
        pbs_status = wait(lambda: (s := hub.client().status()["pbs"])["audio_ready"] and s)
        assert pbs_status["state"] == "streaming" and pbs_status["error"] is None
        assert pbs_status["video_ready"] and (pbs_status["width"], pbs_status["height"]) == (1920, 1080)
        assert status["remote_play"] is None
        assert {"GET /config.json", "GET /frames", "GET /audio"} <= set(pbs.requests)
    finally:
        hub.stop()


@needs_pbs_build
def test_audio_loss_clears_readiness_while_video_continues(padd, pbs):
    hub = start(padd, pbs.port)
    try:
        client = hub.client()
        wait(lambda: client.status()["pbs"]["audio_ready"])
        pbs.audio_down = True
        wait(lambda: not client.status()["pbs"]["audio_ready"])
        assert client.status()["pbs"]["video_ready"]
        pbs.audio_down = False
        wait(lambda: client.status()["pbs"]["audio_ready"])
    finally:
        hub.stop()


@needs_pbs_build
def test_decode_failure_requests_a_keyframe(padd, pbs):
    slice_without_idr = b"\0\0\0\1\x41\x9a\x00\x00"
    pbs.first = [struct.pack(">II", len(slice_without_idr), 0) + slice_without_idr]
    hub = start(padd, pbs.port)
    try:
        wait(lambda: "POST /video/keyframe" in pbs.requests)
        assert hub.client().status()["frames"] > 0
    finally:
        hub.stop()


@needs_pbs_build
def test_oversized_packet_reconnects_instead_of_buffering(padd, pbs):
    pbs.first = [struct.pack(">II", 0x7fffffff, 0)]
    hub = start(padd, pbs.port)
    try:
        assert pbs.requests.count("GET /frames") >= 2
        assert hub.client().status()["frames"] > 0
    finally:
        hub.stop()


@needs_pbs_build
def test_missing_payload_explains_itself_and_recovers(padd, pbs):
    picture, port = (pbs.sps, pbs.pps, pbs.picture), pbs.port
    pbs.stop()
    late: list[FakePBS] = []
    timer = threading.Timer(3, lambda: late.append(FakePBS(*picture, port=port)))
    timer.start()
    try:  # App waits for frames, so returning means the source found the service once it appeared
        hub = start(padd, port)
        try:
            wait(lambda: (s := hub.client().status())["pbs"]["video_ready"] and s["notice"] is None)
        finally:
            hub.stop()
    finally:
        timer.join()
        for fake in late:
            fake.stop()


@needs_pbs_build
def test_lost_stream_clears_snapshot_then_reconnects(padd, tmp_path):
    fake = FakePBS(*blue_frame(tmp_path))
    hub = start(padd, fake.port)
    try:
        assert wait(lambda: hub.client().status()["pbs"]["video_ready"])
        port = fake.port
        picture = (fake.sps, fake.pps, fake.picture)
        fake.stop()
        # The state changes first; the notice follows on the main queue.
        lost = wait(lambda: (s := hub.client().status())["pbs"]["state"] == "reconnecting"
                    and "Load the PBS payload" in (s["notice"] or "") and s)
        assert lost["pbs"]["video_ready"] is False
        assert lost["pbs"]["reconnects"] >= 1
        assert capture.NativeApp(hub.root).status()["frame_age"] < 0 or not (hub.root / "latest.jpg").exists()

        back = FakePBS(*picture, port=port)
        try:
            wait(lambda: (s := hub.client().status())["pbs"]["video_ready"] and s["notice"] is None, timeout=15)
        finally:
            back.stop()
    finally:
        hub.stop()


def test_load_reconnect_and_stop_payload(pbs, tmp_path):
    binary = tmp_path / "pbs-tests"
    compiled = subprocess.run([
        "swiftc", *(str(ROOT / "app" / name) for name in ("PBSSource.swift", "RemotePlayDecoder.swift",
                                                         "RemotePlayAudio.swift", "Frames.swift", "FrameDiff.swift", "FrameMeter.swift",
                                                         "Video.swift")),
        str(ROOT / "tests/native/PBSSourceTests.swift"), "-parse-as-library", "-D", "PS5MCP_PBS", "-framework", "VideoToolbox",
        "-framework", "AVFoundation", "-framework", "CoreImage", "-framework", "AppKit", "-o", str(binary),
    ], check=False, capture_output=True, text=True)
    assert compiled.returncode == 0, compiled.stderr
    dead = socket.socket()
    dead.bind(("127.0.0.1", 0))
    closed_port = dead.getsockname()[1]
    dead.close()
    library = "/data/pldmgr/payloads/PBS-Payload/PBS-Payload-0.1.0-ps5.elf"
    pbs.library = ["/data/pldmgr/payloads/zftpd/zftpd.elf", library]
    empty = FakePBS(pbs.sps, pbs.pps, pbs.picture)
    try:
        result = subprocess.run([str(binary), str(pbs.port), str(closed_port), str(tmp_path / "latest.jpg"), str(empty.port)],
                                check=False, capture_output=True, text=True, timeout=60)
    finally:
        empty.stop()
    assert result.returncode == 0, result.stdout + result.stderr
    assert "pbs source checks passed" in result.stdout
    assert pbs.requests.count("GET /frames") >= 2  # reconnect opened a new stream
    assert pbs.requests.count("POST /stop") == 1
    assert f"GET /loadpayload:{library}" in pbs.requests
    assert not [request for request in empty.requests if "/loadpayload" in request]


@needs_pbs_build
def test_window_shows_network_source_frames_faster_than_15_fps(padd, pbs):
    hub = start(padd, pbs.port)
    try:
        client = hub.client()
        assert client.status()["preview_frames"] == 0  # headless: nothing to draw
        client.call("show")
        wait(lambda: client.status()["preview_frames"] > 0, timeout=5)
        first = client.status()["preview_frames"]
        started = time.monotonic()
        time.sleep(2)
        rate = (client.status()["preview_frames"] - first) / (time.monotonic() - started)
        assert rate > 20, f"window drew {rate:.1f} fps of a 30 fps stream"
    finally:
        hub.stop()


def test_pbs_cannot_fall_back_to_ffmpeg(tmp_path):
    with pytest.raises(capture.CaptureError, match="PBS requires the native app"):
        capture.daemon_command(tmp_path / "latest.jpg", video="pbs")


@pytest.mark.skipif(_has_pbs(), reason="this build has PBS")
def test_a_normal_build_has_no_pbs_and_leaves_a_saved_pbs_source(padd, tmp_path):
    assert b"Waiting for PBS at" not in APP.read_bytes()
    root = Path(tempfile.mkdtemp(prefix="a", dir="/tmp"))  # AF_UNIX paths are limited to ~104 bytes
    log = (root / "app.log").open("wb")
    app = subprocess.Popen([str(APP), "--state-dir", str(root), "--video", "pbs", "--audio", "pbs", "--headless",
                            "--host", "127.0.0.1", "--port", str(padd.port)], stdout=log, stderr=subprocess.STDOUT)
    try:
        status = wait(lambda: capture.NativeApp(root).status())
        assert status["source"] != "pbs" and status["pbs"] is None
        assert "no PBS source" in (root / "app.log").read_text()
        client = AppClient(root / "capture.sock")
        client.call("capture_restart", video="pbs", audio="pbs")
        client.close()
        assert capture.NativeApp(root).status()["source"] != "pbs"
        assert (root / "app.log").read_text().count("no PBS source") == 2  # the API takes the same fallback
    finally:
        app.terminate()
        app.wait(5)
        log.close()
        shutil.rmtree(root, ignore_errors=True)
