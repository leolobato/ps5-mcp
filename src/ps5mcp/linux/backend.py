"""Process adapter for the Python hub, using the existing local JSON API."""
from __future__ import annotations

import base64
import io
import os
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

from ..capture import CaptureError, NativeApp


class LinuxHub(NativeApp):
    # Reuse the platform-independent socket/status helpers, never NativeApp.start/stop.
    def __init__(self, root: Path | None = None):
        root = root or Path(os.environ.get("PS5MCP_STATE", Path.home() / ".local/state/ps5-mcp"))
        super().__init__(root, binary=Path(sys.executable))
        self.log = self.root / "linux-hub.log"
        self._process = None

    start_options = ("video_format", "video_size", "video_fps", "stale_s", "viewer_port", "host", "padd_port")
    browser_viewer = True

    def console_allowed(self) -> bool:
        return console_enabled()

    def viewer_url(self) -> str | None:
        return (self.status() or {}).get("viewer_url")

    def capture_error(self) -> str | None:
        return (self.status() or {}).get("capture_error")

    @property
    def client_type(self):
        from .controller import LinuxAppClient
        return LinuxAppClient

    def start(self, **options) -> int:
        import fcntl

        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Serialize independent MCP startup attempts before creating any child process.
        with (self.root / "start.lock").open("a") as lock:
            deadline = time.monotonic() + options.get("timeout", 15)
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise CaptureError("Another client is still starting the Linux hub") from None
                    time.sleep(0.05)
            return self._start(**options)

    def _start(self, video=None, audio=None, visible=False, host=None, timeout=15,
              video_format=None, video_size=None, video_fps=None, stale_s=None, viewer_port=None, padd_port=None) -> int:
        if audio not in (None, "none"):
            raise CaptureError("Linux audio capture is not supported")
        env = os.environ.copy()
        overrides = {"PS5MCP_VIDEO_FORMAT": video_format, "PS5MCP_VIDEO_SIZE": video_size,
                     "PS5MCP_VIDEO_FPS": video_fps, "PS5MCP_VIDEO_STALE_S": stale_s,
                     "PS5MCP_VIEWER_PORT": viewer_port, "PS5MCP_PAD_PORT": padd_port}
        env.update({key: str(value) for key, value in overrides.items() if value is not None})
        try:
            port = int(env.get("PS5MCP_VIEWER_PORT", "0"))
            if not 0 <= port <= 65535:
                raise ValueError
        except ValueError:
            raise CaptureError("PS5MCP_VIEWER_PORT must be 0..65535") from None
        from .controller import ConnectionConfig
        try:
            connection = ConnectionConfig(host or env.get("PS5_HOST"), int(env.get("PS5MCP_PAD_PORT", "9305")),
                                          env.get("PS5MCP_ALLOW_CONSOLE") == "1")
            connection.validate()
        except ValueError as exc:
            raise CaptureError(str(exc)) from exc
        requested = video or env.get("PS5MCP_VIDEO")
        if status := self.status():
            actual = status.get("video_config", {}).get("source", status.get("configured_source", status["source"]))
            config = status.get("video_config", {})
            conflicts = requested is not None and requested != actual
            for key, value in (("input_format", env.get("PS5MCP_VIDEO_FORMAT")),
                               ("size", env.get("PS5MCP_VIDEO_SIZE")), ("fps", env.get("PS5MCP_VIDEO_FPS"))):
                conflicts |= value is not None and str(value) != config.get(key)
            if (configured_stale := env.get("PS5MCP_VIDEO_STALE_S")) is not None:
                conflicts |= float(configured_stale) != status.get("stale_after_s")
            if port:
                conflicts |= status.get("viewer_url") != f"http://127.0.0.1:{port}/"
            if host is not None:
                conflicts |= status["pad"].get("host") != host
            if padd_port is not None:
                conflicts |= status["pad"].get("port") != padd_port
            if (connection.enabled and status["pad"].get("enabled") and
                    (status["pad"].get("host") != connection.host or status["pad"].get("port") != connection.port)):
                raise CaptureError("The shared hub uses a different padd endpoint; stop it explicitly before changing consoles")
            if connection.enabled and not status["pad"].get("enabled"):
                raise CaptureError("The shared hub is offline; restart it explicitly to enable padd")
            if conflicts:
                raise CaptureError("A hub is already running with different capture settings; "
                                   "stop it explicitly before changing the physical input")
            return status["pid"]
        if requested and requested.startswith(("/dev/", "v4l2:", "lavfi:")):
            from .video import VideoConfig
            try:
                VideoConfig(requested, env.get("PS5MCP_VIDEO_FORMAT"), env.get("PS5MCP_VIDEO_SIZE"),
                            env.get("PS5MCP_VIDEO_FPS"), float(env.get("PS5MCP_VIDEO_STALE_S", "2"))).validate()
            except ValueError as exc:
                raise CaptureError(f"Invalid capture settings: {exc}") from exc
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        command = [sys.executable, "-m", "ps5mcp.linux.hub", "--state-dir", str(self.root)]
        if video is not None:
            command += ["--video", video]
        # Host alone never authorizes a connection. The child checks the explicit opt-in.
        if host:
            command += ["--host", host]
        with self.log.open("ab") as log:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                       start_new_session=True, env=env)
        self._process = process
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if status := self.status():
                if status["pid"] != process.pid:
                    process.wait(timeout=3)
                return status["pid"]
            if process.poll() is not None:
                detail = self.log.read_text(errors="replace")[-2048:].strip()
                raise CaptureError(f"Linux hub exited ({process.returncode}): {detail}; see {self.log}")
            time.sleep(0.05)
        process.terminate()
        process.wait(timeout=3)
        raise CaptureError(f"Linux hub startup timed out; see {self.log}")

    def stop(self, grace=3) -> bool:
        if self.status() is None:
            if self._process is not None:
                self._process.poll()
            return False
        self.request("quit")
        deadline = time.monotonic() + grace
        while self.status() is not None:
            if time.monotonic() > deadline:
                raise CaptureError("Linux hub did not shut down within timeout")
            time.sleep(0.02)
        if self._process is not None:
            self._process.wait(timeout=grace)
        return True

    def refresh(self) -> None:
        reply = self.request("snapshot")[0]
        if not reply.get("ok"):
            raise CaptureError(reply.get("error", "Linux capture failed"))

    def read_frame(self):
        reply = self.request("snapshot", include_data=True)[0]
        if not reply.get("ok"):
            raise CaptureError(reply.get("error", "Linux capture failed"))
        return base64.b64decode(reply.pop("jpeg_base64")), reply

    def save_snapshot(self, destination, max_width=None):
        if self.pid() is None:
            self.start()
        data, _ = self.read_frame()
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if max_width is not None and (type(max_width) is not int or max_width <= 0):
            raise CaptureError("max_width must be a positive integer")
        with Image.open(io.BytesIO(data)) as image:
            if max_width and image.width > max_width:
                image = image.resize((max_width, max(1, round(image.height * max_width / image.width))))
            image.save(destination)
        return destination

    def show(self) -> None:
        reply = self.request("show")[0]
        if not reply.get("ok"):
            raise CaptureError(reply.get("error", "Linux viewer is unavailable"))

    def watch_change(self, threshold=6, timeout=2):
        raise CaptureError("Linux watch_change is not supported; use wait_for templates")


def console_enabled() -> bool:
    return os.environ.get("PS5MCP_ALLOW_CONSOLE") == "1"
