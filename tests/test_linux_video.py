"""Physical input command tests and real FFmpeg lavfi fanout; never open /dev/video*."""
from __future__ import annotations

import concurrent.futures
import io
import json
import shutil
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.request

import pytest
from PIL import Image

from ps5mcp import capture, server
from ps5mcp.hub import AppClient
from ps5mcp.linux.backend import LinuxHub
from ps5mcp.linux.hub import Hub, serve
from ps5mcp.linux.video import FFmpegCapture, VideoConfig, device_lock

SOURCE = "lavfi:testsrc2=size=320x180:rate=20"


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
    for key in ("PS5_HOST", "PS5MCP_VIDEO", "PS5MCP_VIDEO_FORMAT", "PS5MCP_VIDEO_SIZE", "PS5MCP_VIDEO_FPS"):
        monkeypatch.delenv(key, raising=False)


@pytest.fixture
def video_hub(tmp_path):
    if not shutil.which("ffmpeg"):
        pytest.skip("requires FFmpeg with lavfi and mjpeg")
    config = VideoConfig(SOURCE, stale_s=0.6, retry_s=0.1)
    hub = Hub(tmp_path, SOURCE, video_config=config)
    ready = threading.Event()
    thread = threading.Thread(target=serve, args=(hub, ready))
    thread.start()
    try:
        assert ready.wait(3)
        assert wait(lambda: hub.video_capture.info()["capture_error"] is None)
        yield hub
    finally:
        if hub.server:
            hub.server.shutdown()
        thread.join(5)
        assert not thread.is_alive()
        assert hub.video_capture.process is None


def test_explicit_v4l2_config_and_command():
    config = VideoConfig("v4l2:/dev/video99", "mjpeg", "1920x1080", "60000/1001")
    command = config.command()
    assert command.count("-i") == 1
    assert command[command.index("-i") + 1] == "/dev/video99"
    for arg in ("v4l2", "mjpeg", "1920x1080", "60000/1001", "image2pipe", "pipe:1", "-an"):
        assert arg in command
    assert "avfoundation" not in command
    with pytest.raises(capture.CaptureError, match="explicit"):
        VideoConfig("/dev/video99").validate()


@pytest.mark.parametrize("kwargs", [{"size": "bad"}, {"fps": "0"}, {"fps": "1/0"}, {"fps": "nan"},
                                   {"stale_s": float("nan")}, {"input_format": "mjpeg -bad"}])
def test_invalid_configuration(kwargs):
    fields = {"input_format": "mjpeg", "size": "1280x720", "fps": "30"}
    fields.update(kwargs)
    with pytest.raises(capture.CaptureError):
        VideoConfig("/dev/video99", **fields).validate()


def test_device_lock_across_state_directories(tmp_path):
    # Lock only: no capture process and no device open.
    lock = device_lock("/dev/ps5-mcp-offline-lock-test")
    try:
        with pytest.raises(capture.CaptureError, match="already owned"):
            device_lock("/dev/ps5-mcp-offline-lock-test")
    finally:
        lock.close()
    device_lock("/dev/ps5-mcp-offline-lock-test").close()


def test_many_clients_one_process_and_timestamped_frames(video_hub):
    hub = video_hub
    clients = [AppClient(hub.root / "capture.sock", client=f"mcp-{i}") for i in range(5)]
    backend = LinuxHub(hub.root)
    try:
        before = clients[0].status()
        def snapshot(client):
            return client.call("snapshot", include_data=True)
        with concurrent.futures.ThreadPoolExecutor() as pool:
            replies = list(pool.map(snapshot, clients))
        assert all(r["frame_timestamp_unix"] > 0 and r["frame_timestamp"] > 0 for r in replies)
        assert before["capture_starts"] == clients[-1].status()["capture_starts"] == 1
        assert {c.status()["ffmpeg_pid"] for c in clients} == {before["ffmpeg_pid"]}
        assert backend.start() == before["pid"]
        with pytest.raises(capture.CaptureError, match="different capture settings"):
            backend.start(video="synthetic")
        image = capture.snapshot(hub.root / "small.png", max_width=160, daemon=backend)
        with Image.open(image) as image:
            assert image.size == (160, 90)
        assert wait(lambda: clients[0].status()["frame_sequence"] > replies[0]["frame_sequence"])
    finally:
        for client in clients:
            client.close()


def read_multipart_frame(response):
    assert response.readline().strip() == b"--ps5frame"
    headers = {}
    while (line := response.readline().strip()):
        key, value = line.decode().split(":", 1)
        headers[key] = value.strip()
    data = response.read(int(headers["Content-Length"]))
    assert response.read(2) == b"\r\n"
    with Image.open(io.BytesIO(data)) as image:
        assert image.size == (320, 180)
    return headers


def test_multiple_live_viewers(video_hub):
    url = video_hub.status()["viewer_url"]
    streams = [urllib.request.urlopen(url + "stream.mjpg", timeout=3) for _ in range(3)]
    try:
        first = [read_multipart_frame(stream) for stream in streams]
        second = [read_multipart_frame(stream) for stream in streams]
        assert all(int(b["X-Frame-Sequence"]) > int(a["X-Frame-Sequence"]) for a, b in zip(first, second))
        assert video_hub.video_capture.starts == 1
        with urllib.request.urlopen(url + "snapshot.jpg", timeout=3) as response:
            assert response.headers["X-Frame-Timestamp"]
            assert response.read().startswith(b"\xff\xd8")
        with urllib.request.urlopen(url + "status.json", timeout=3) as response:
            assert json.load(response)["ffmpeg_pid"] == video_hub.video_capture.process.pid
    finally:
        for stream in streams:
            stream.close()


def test_capture_exit_and_recovery(video_hub):
    source = video_hub.video_capture
    previous = source.get()
    pid = source.process.pid
    source.process.kill()
    assert wait(lambda: source.info()["capture_error"] is not None)
    with pytest.raises(capture.CaptureError):
        source.get()
    assert wait(lambda: source.info()["capture_error"] is None and source.starts >= 2)
    frame = source.get()
    assert frame.monotonic > previous.monotonic
    assert frame.sequence > previous.sequence
    assert source.process.pid != pid


def test_stalled_input_http_failure_and_recovery(video_hub):
    source = video_hub.video_capture
    process = source.process
    previous = source.get()
    process.send_signal(signal.SIGSTOP)
    try:
        assert wait(lambda: source.info()["capture_error"] is not None)
        with pytest.raises(capture.CaptureError):
            LinuxHub(video_hub.root).read_frame()
        with pytest.raises(urllib.error.HTTPError) as exc:
            urllib.request.urlopen(video_hub.status()["viewer_url"] + "snapshot.jpg", timeout=3)
        assert exc.value.code == 503
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGCONT)
    assert wait(lambda: source.info()["capture_error"] is None and source.get().monotonic > previous.monotonic)
    with urllib.request.urlopen(video_hub.status()["viewer_url"] + "stream.mjpg", timeout=3) as response:
        read_multipart_frame(response)


def test_busy_device_diagnostics_without_device_access(tmp_path, monkeypatch):
    # Replace FFmpeg with a harmless child that prints the real-world busy diagnostic.
    import sys
    real_popen = subprocess.Popen
    def busy(*args, **kwargs):
        return real_popen([sys.executable, "-c", "import sys; print('Device or resource busy', file=sys.stderr)"],
                          **kwargs)
    monkeypatch.setattr(subprocess, "Popen", busy)
    source = FFmpegCapture(VideoConfig("/dev/video99", "mjpeg", "320x180", "20", retry_s=1), tmp_path / "frame.jpg")
    source.start()
    try:
        assert wait(lambda: "busy" in (source.info()["capture_error"] or ""))
        assert "MJPEG stream" in source.info()["capture_error"]
    finally:
        source.stop()


async def test_mcp_frames_and_metadata(video_hub, monkeypatch):
    monkeypatch.setenv("PS5MCP_STATE", str(video_hub.root))
    monkeypatch.setattr(server, "runtime", server.Runtime())
    try:
        async with server.lifespan(server.mcp):
            result = await server.mcp.call_tool("snapshot", {"max_width": 160})
            assert result.content[0].type == "image"
            info = await server.mcp.call_tool("status", {})
            data = json.loads(info.content[0].text)["capture"]
            assert data["frame_timestamp"] > 0
            assert data["frame_timestamp_unix"] > 0
            assert data["capture_starts"] == 1
            result = await server.mcp.call_tool("show_viewer", {})
            assert video_hub.status()["viewer_url"] in result.content[0].text
    finally:
        server.runtime.stop()


def test_missing_ffmpeg_and_clean_shutdown(tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", "/does-not-exist")
    source = FFmpegCapture(VideoConfig(SOURCE, retry_s=0.1), tmp_path / "frame.jpg")
    source.start()
    try:
        assert wait(lambda: "No such file" in (source.info()["capture_error"] or ""))
    finally:
        source.stop()


def test_concurrent_hub_start_uses_one_capture(tmp_path, monkeypatch):
    monkeypatch.setenv("PS5MCP_STATE", str(tmp_path))
    monkeypatch.setenv("PS5MCP_VIDEO", SOURCE)
    adapters = [LinuxHub(tmp_path) for _ in range(3)]
    try:
        with concurrent.futures.ThreadPoolExecutor() as pool:
            pids = list(pool.map(lambda b: b.start(), adapters))
        assert len(set(pids)) == 1
        assert wait(lambda: adapters[0].status()["capture_error"] is None)
        assert adapters[0].status()["capture_starts"] == 1
    finally:
        adapters[0].stop()


def test_slow_consumer_does_not_block_capture(video_hub):
    source = video_hub.video_capture
    with urllib.request.urlopen(video_hub.status()["viewer_url"] + "stream.mjpg", timeout=3):
        # Deliberately leave the response unread while capture and screenshots continue.
        sequence = source.get().sequence
        assert wait(lambda: source.get().sequence >= sequence + 20)
        assert LinuxHub(video_hub.root).read_frame()[0].startswith(b"\xff\xd8")
        assert source.starts == 1


def test_device_disappearance_then_return_without_hardware(tmp_path, monkeypatch):
    import sys

    real_popen = subprocess.Popen
    attempts = []
    def disconnected_then_returned(command, **kwargs):
        attempts.append(command)
        if len(attempts) == 1:
            command = [sys.executable, "-c", "import sys; print('No such device', file=sys.stderr)"]
        return real_popen(command, **kwargs)
    monkeypatch.setattr(subprocess, "Popen", disconnected_then_returned)
    source = FFmpegCapture(VideoConfig(SOURCE, retry_s=0.4), tmp_path / "frame.jpg")
    source.start()
    try:
        assert wait(lambda: "No such device" in (source.info()["capture_error"] or ""))
        assert wait(lambda: source.info()["capture_error"] is None)
        assert source.starts == 2
        assert source.get().sequence >= 1
    finally:
        source.stop()


def test_per_device_lock_released_on_shutdown(tmp_path, monkeypatch):
    # The input command is replaced by lavfi, but the physical-device ownership path is exercised.
    original = VideoConfig.command
    monkeypatch.setattr(VideoConfig, "command", lambda _: original(VideoConfig(SOURCE)))
    config = VideoConfig("/dev/ps5-mcp-offline-lock-test", "mjpeg", "320x180", "20")
    first = FFmpegCapture(config, tmp_path / "first.jpg")
    second = FFmpegCapture(config, tmp_path / "second.jpg")
    first.start()
    try:
        assert wait(lambda: first.info()["capture_error"] is None)
        with pytest.raises(capture.CaptureError, match="already owned"):
            second.start()
    finally:
        first.stop()
    second.start()
    try:
        assert wait(lambda: second.info()["capture_error"] is None)
    finally:
        second.stop()


def test_ffmpeg_consumer_can_read_mjpeg_for_loopback_bridge(video_hub):
    process = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "mpjpeg",
                              "-i", video_hub.status()["viewer_url"] + "stream.mjpg",
                              "-frames:v", "3", "-pix_fmt", "yuv420p", "-c:v", "rawvideo",
                              "-threads", "1", "-f", "null", "-"],
                             capture_output=True, timeout=10, check=False)
    assert process.returncode == 0, process.stderr.decode()
    assert video_hub.video_capture.starts == 1


def test_physical_mjpeg_passthrough_preserves_original_frames():
    command = VideoConfig("/dev/video99", "mjpeg", "1920x1080", "60").command()
    assert command[command.index("-c:v") + 1] == "copy"
    assert command[command.index("-fps_mode") + 1] == "passthrough"
    assert "-q:v" not in command
    raw = VideoConfig("/dev/video99", "yuyv422", "1920x1080", "60").command()
    assert raw[raw.index("-c:v") + 1] == "mjpeg"
    assert VideoConfig(SOURCE).command()[VideoConfig(SOURCE).command().index("-c:v") + 1] == "mjpeg"
