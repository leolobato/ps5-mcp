"""The Linux hub's PBS video source, against a loopback fake of the PBS HTTP service; never a console."""
from __future__ import annotations

import io
import json
import shutil
import socket
import socketserver
import struct
import subprocess
import threading
import time

import pytest
from PIL import Image

from ps5mcp.capture import CaptureError
from ps5mcp.linux.backend import LinuxHub
from ps5mcp.linux.hub import Hub
from ps5mcp.linux.video import ACCESS_UNIT_DELIMITER, PBSCapture, VideoConfig, pbs_parameter_sets


def wait(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


@pytest.fixture(autouse=True)
def offline(monkeypatch):
    monkeypatch.setenv("PS5MCP_ALLOW_CONSOLE", "0")
    monkeypatch.setenv("PS5MCP_BACKEND", "linux")
    for key in ("PS5_HOST", "PS5MCP_VIDEO", "PS5MCP_PBS_PORT"):
        monkeypatch.delenv(key, raising=False)


def nal_units(stream):
    starts = []
    index = stream.find(b"\x00\x00\x01")
    while index >= 0:
        starts.append(index + 3)
        index = stream.find(b"\x00\x00\x01", index + 3)
    units = []
    for number, start in enumerate(starts):
        end = starts[number + 1] - 3 if number + 1 < len(starts) else len(stream)
        units.append(stream[start:end].rstrip(b"\x00"))
    return units


@pytest.fixture(scope="module")
def h264():
    """An x264 stream like PBS's: SPS and PPS for /config.json, then one Annex B picture per packet."""
    if not shutil.which("ffmpeg"):
        pytest.skip("requires FFmpeg")
    result = subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=20",
         "-frames:v", "60", "-c:v", "libx264", "-threads", "1", "-tune", "zerolatency", "-g", "20",
         "-color_range", "tv", "-pix_fmt", "yuv420p", "-f", "h264", "pipe:1"],
        capture_output=True, check=False)
    if result.returncode:
        pytest.skip(f"requires FFmpeg with libx264: {result.stderr.decode(errors='replace')[-200:]}")
    units = nal_units(result.stdout)
    sps = next(u for u in units if u[0] & 0x1f == 7)
    pps = next(u for u in units if u[0] & 0x1f == 8)
    pictures = [b"\x00\x00\x00\x01" + u for u in units if u[0] & 0x1f in (1, 5)]
    assert pictures[0][4] & 0x1f == 5 and len(pictures) == 60
    return {"sps": sps.hex(), "pps": pps.hex(), "pictures": pictures}


class FakePBS(socketserver.ThreadingTCPServer):
    """Serves /config.json and /frames as PBS does: an HTTP/1.1 header, then length+timestamp framed packets
    until the connection closes."""
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, h264):
        super().__init__(("127.0.0.1", 0), FakePBSHandler)
        self.h264 = h264
        self.first_delay = 0.0     # seconds before the first picture, as PBS waits for its next IDR
        self.limit = None          # close /frames after this many pictures
        self.hold_after = None     # stop sending (but keep the connection) after this many pictures
        self.streams = 0
        self.stop_sending = threading.Event()

    @property
    def port(self):
        return self.server_address[1]


class FakePBSHandler(socketserver.StreamRequestHandler):
    def handle(self):
        request = self.rfile.readline().decode()
        while self.rfile.readline() not in (b"\r\n", b""):
            pass
        path = request.split()[1] if len(request.split()) > 1 else ""
        server = self.server
        if path == "/config.json":
            body = json.dumps({"platform": "PS5", "width": 320, "height": 180, "fps": 20,
                               "sps": server.h264["sps"], "pps": server.h264["pps"]}).encode()
            self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n"
                             b"Connection: close\r\n\r\n%s" % (len(body), body))
            return
        if path != "/frames":
            self.wfile.write(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n")
            return
        server.streams += 1
        self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n")
        self.wfile.flush()
        if server.stop_sending.wait(server.first_delay):
            return
        sent = 0
        pictures = server.h264["pictures"]
        try:
            while not server.stop_sending.is_set():
                if server.limit is not None and sent >= server.limit:
                    return
                if server.hold_after is not None and sent >= server.hold_after:
                    server.stop_sending.wait(10)
                    return
                picture = pictures[sent % len(pictures)]
                self.wfile.write(struct.pack(">II", len(picture), sent) + picture)
                self.wfile.flush()
                sent += 1
                time.sleep(0.05)
        except OSError:
            pass


@pytest.fixture
def pbs(h264):
    server = FakePBS(h264)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.stop_sending.set()
        server.shutdown()
        server.server_close()


@pytest.fixture
def capture(pbs, tmp_path):
    sources = []

    def start(stale_s=0.6, startup_s=None):
        source = PBSCapture(VideoConfig("pbs", stale_s=stale_s, retry_s=0.1), tmp_path / "latest.jpg",
                            "127.0.0.1", pbs.port)
        if startup_s is not None:
            source.startup_s = startup_s
        source.start()
        sources.append(source)
        return source

    yield start
    for source in sources:
        source.stop()
        assert source.process is None


def test_ffmpeg_command_decodes_h264_from_stdin_to_full_range_jpeg():
    command = VideoConfig("pbs").command()
    assert command[command.index("-f") + 1] == "h264" and command[command.index("-i") + 1] == "pipe:0"
    assert "-nostdin" not in command
    assert "nobuffer" not in command  # makes FFmpeg 8 drop every picture of a piped H.264 stream
    assert "scale=out_range=full,format=yuvj420p" in command
    assert VideoConfig("pbs").device is None


def test_parameter_sets_from_config():
    assert pbs_parameter_sets({"sps": "6742", "pps": "68ce"}) == bytes.fromhex("00000001674200000001" "68ce")
    for bad in ({}, {"sps": "", "pps": "68"}, {"sps": "zz", "pps": "68"}, {"sps": 1, "pps": "68"}):
        with pytest.raises(CaptureError, match="sps and pps"):
            pbs_parameter_sets(bad)


def test_frames_arrive_as_jpeg_with_timestamps(capture, pbs):
    source = capture()
    assert wait(lambda: source.info()["capture_error"] is None)
    first = source.get()
    with Image.open(io.BytesIO(first.jpeg)) as image:
        assert image.format == "JPEG" and image.size == (320, 180)
    assert wait(lambda: source.get().sequence >= first.sequence + 5)
    info = source.info()
    assert info["pbs"] == {"host": "127.0.0.1", "port": pbs.port, "size": "320x180"}
    assert info["ffmpeg_pid"] is not None and info["capture_starts"] == 1


def test_newest_picture_is_decoded_without_waiting_for_the_next(capture, pbs):
    # A still console screen may send nothing more: every picture received must already be a frame.
    pbs.hold_after = 4
    source = capture(stale_s=5)
    assert wait(lambda: source.info()["frame_sequence"] == 4, seconds=5)
    time.sleep(0.5)
    assert source.info()["frame_sequence"] == 4
    assert ACCESS_UNIT_DELIMITER[4] & 0x1f == 9


def test_slow_first_idr_is_not_treated_as_stale(capture, pbs):
    pbs.first_delay = 1.5
    source = capture(stale_s=0.6, startup_s=4)
    assert wait(lambda: source.info()["frame_sequence"] > 0, seconds=5)
    assert source.info()["capture_starts"] == 1 and pbs.streams == 1


def test_lost_stream_reports_pbs_and_reconnects(capture, pbs):
    pbs.limit = 10
    source = capture()
    assert wait(lambda: source.info()["frame_sequence"] >= 5)
    assert wait(lambda: "PBS closed the video stream" in (source.info()["capture_error"] or ""))
    with pytest.raises(CaptureError):
        source.get()
    previous = source.info()["frame_sequence"]
    pbs.limit = None
    assert wait(lambda: source.info()["capture_error"] is None and source.info()["frame_sequence"] > previous)
    assert source.info()["capture_starts"] >= 2


def test_unreachable_pbs_says_how_to_load_it(tmp_path):
    with socket.socket() as reserved:
        reserved.bind(("127.0.0.1", 0))
        port = reserved.getsockname()[1]
    source = PBSCapture(VideoConfig("pbs", retry_s=0.1), tmp_path / "latest.jpg", "127.0.0.1", port)
    source.start()
    try:
        assert wait(lambda: "Waiting for PBS at 127.0.0.1" in (source.info()["capture_error"] or ""))
        assert "ps5mcp get-pbs --run" in source.info()["capture_error"]
        assert source.info()["capture_starts"] == 0
    finally:
        source.stop()


def test_stop_unblocks_a_stream_waiting_for_its_first_idr(capture, pbs):
    pbs.first_delay = 30
    source = capture(startup_s=30)
    assert wait(lambda: source.process is not None)
    started = time.monotonic()
    source.stop()
    assert time.monotonic() - started < 3


def test_hub_requires_console_opt_in_for_pbs(tmp_path, monkeypatch):
    hub = Hub(tmp_path, "pbs")
    hub.start_capture()
    assert hub.video_capture is None
    assert "PS5MCP_ALLOW_CONSOLE=1" in hub.status()["capture_error"]
    with pytest.raises(CaptureError, match="PS5MCP_ALLOW_CONSOLE=1"):
        LinuxHub(tmp_path).start(video="pbs")


def test_hub_streams_pbs_when_console_access_is_enabled(tmp_path, monkeypatch, pbs):
    monkeypatch.setenv("PS5MCP_ALLOW_CONSOLE", "1")
    monkeypatch.setenv("PS5_HOST", "127.0.0.1")
    monkeypatch.setenv("PS5MCP_PBS_PORT", str(pbs.port))
    hub = Hub(tmp_path, "pbs", video_config=VideoConfig("pbs", stale_s=0.6, retry_s=0.1))
    hub.start_capture()
    try:
        assert wait(lambda: hub.status()["capture_error"] is None)
        status = hub.status()
        assert status["source"] == "pbs" and status["video_config"]["pbs_port"] == pbs.port
        assert hub.read_frame().jpeg.startswith(b"\xff\xd8")
    finally:
        hub.video_capture.stop()
