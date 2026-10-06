"""Capture-card access through ffmpeg's AVFoundation input.

AVFoundation gives a capture device to one process at a time, so a single
daemon owns the card and fans it out:

- a low-latency MPEG-TS stream (video + audio) on a local UDP port, for `view`;
- `latest.jpg`, rewritten atomically a few times per second, for `snapshot`.

When the daemon is not running, `snapshot` opens the device directly for one frame.
"""

from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_VIDEO = "eEver USB Video Device"
DEFAULT_AUDIO = "eEver USB Audio Device"
# The eEver card advertises exactly one mode; ffmpeg rejects anything else.
DEFAULT_SIZE = "1920x1080"
DEFAULT_FPS = "60.000240"
DEFAULT_PIXEL_FORMAT = "uyvy422"
STREAM_PORT = 23230
SNAPSHOT_FPS = 5
# A frame older than this means the daemon is wedged or the signal is gone.
MAX_FRAME_AGE = 2.0

_DEVICE_LINE = re.compile(r"\[(\d+)\] (.+)$")


class CaptureError(RuntimeError):
    pass


def console_host(host: str | None = None) -> str:
    """The console's address: `host`, else PS5_HOST. There is no default; every network is different."""
    if host := host or os.environ.get("PS5_HOST"):
        return host
    raise CaptureError("set PS5_HOST to the console's IP address (or pass --host)")


@dataclass
class Devices:
    video: list[str] = field(default_factory=list)
    audio: list[str] = field(default_factory=list)


def state_dir() -> Path:
    path = Path(os.environ.get("PS5MCP_STATE", Path.home() / ".local/state/ps5-mcp"))
    path.mkdir(parents=True, exist_ok=True)
    return path


def parse_device_list(text: str) -> Devices:
    """Parse the stderr of `ffmpeg -f avfoundation -list_devices true -i ""`."""
    devices = Devices()
    section = None
    for line in text.splitlines():
        if "AVFoundation video devices" in line:
            section = devices.video
        elif "AVFoundation audio devices" in line:
            section = devices.audio
        elif section is not None and (match := _DEVICE_LINE.search(line)):
            section.append(match.group(2).strip())
    return devices


def list_devices() -> Devices:
    result = subprocess.run(
        ["ffmpeg", "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
        capture_output=True, text=True, timeout=15, check=False,
    )
    return parse_device_list(result.stderr)


def _input_args(video: str, audio: str | None) -> list[str]:
    return ["-f", "avfoundation", "-framerate", DEFAULT_FPS, "-video_size", DEFAULT_SIZE,
            "-pixel_format", DEFAULT_PIXEL_FORMAT, "-i", f"{video}:{audio or 'none'}"]


def daemon_command(latest: Path, video: str = DEFAULT_VIDEO, audio: str | None = DEFAULT_AUDIO,
                   port: int = STREAM_PORT) -> list[str]:
    stream_maps = ["-map", "0:v"] + (["-map", "0:a"] if audio else [])
    audio_codec = ["-c:a", "aac", "-b:a", "160k"] if audio else []
    return [
        "ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostdin",
        *_input_args(video, audio),
        # Live view: H.264 tuned for latency, sent to whoever listens on the port.
        *stream_maps, "-r", "60", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-pix_fmt", "yuv420p", "-g", "60", "-b:v", "8M", *audio_codec,
        "-f", "mpegts", f"udp://127.0.0.1:{port}?pkt_size=1316",
        # Snapshots: atomic rewrites, so a reader never sees a torn JPEG.
        "-map", "0:v", "-vf", f"fps={SNAPSHOT_FPS}", "-q:v", "2",
        "-update", "1", "-atomic_writing", "1", "-y", str(latest),
    ]


def view_command(port: int = STREAM_PORT, ipc: Path | None = None) -> list[str]:
    url = f"udp://127.0.0.1:{port}"
    if shutil.which("mpv"):
        # mpv keeps the window at the video's aspect ratio while resizing.
        return ["mpv", "--title=PS5", "--profile=low-latency", "--cache=no", "--keepaspect-window=yes",
                "--geometry=1280x720", "--force-window=immediate", "--really-quiet", "--osc=no", "--osd-level=0",
                *([f"--input-ipc-server={ipc}"] if ipc else []), url]
    # ffplay letterboxes on resize instead; at least open at 16:9.
    return ["ffplay", "-hide_banner", "-loglevel", "warning", "-window_title", "PS5", "-x", "1280", "-y", "720",
            "-fflags", "nobuffer", "-flags", "low_delay", "-framedrop", url]


class Daemon:
    def __init__(self, root: Path | None = None):
        self.root = root or state_dir()
        self.pidfile = self.root / "capture.pid"
        self.latest = self.root / "latest.jpg"
        self.log = self.root / "capture.log"

    def pid(self) -> int | None:
        try:
            pid = int(self.pidfile.read_text().strip())
            os.kill(pid, 0)
            return pid
        except (FileNotFoundError, ValueError, ProcessLookupError, PermissionError):
            return None

    def frame_age(self) -> float | None:
        try:
            return time.time() - self.latest.stat().st_mtime
        except FileNotFoundError:
            return None

    def start(self, video: str = DEFAULT_VIDEO, audio: str | None = DEFAULT_AUDIO,
              timeout: float = 10) -> int:
        if (pid := self.pid()) is not None:
            return pid
        self.latest.unlink(missing_ok=True)
        with self.log.open("ab") as log:
            process = subprocess.Popen(daemon_command(self.latest, video, audio), stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=log, start_new_session=True)
        self.pidfile.write_text(f"{process.pid}\n")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if process.poll() is not None:
                self.pidfile.unlink(missing_ok=True)
                raise CaptureError(f"ffmpeg exited with {process.returncode}; see {self.log}")
            if self.latest.exists():
                return process.pid
            time.sleep(0.2)
        self.stop()
        raise CaptureError("No frame within timeout. Is another app (QuickTime, OBS) holding the card, "
                           "or is camera permission missing for this terminal?")

    def stop(self, grace: float = 3) -> bool:
        pid = self.pid()
        if pid is None:
            self.pidfile.unlink(missing_ok=True)
            return False
        # ffmpeg finalises cleanly on SIGINT; AVFoundation can wedge, so escalate.
        os.kill(pid, signal.SIGINT)
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline and self.pid() == pid:
            time.sleep(0.1)
        if self.pid() == pid:
            os.kill(pid, signal.SIGKILL)
        self.pidfile.unlink(missing_ok=True)
        return True


    def refresh(self) -> None:
        """latest.jpg is already rewritten at SNAPSHOT_FPS."""


APP_BUNDLE = Path(__file__).resolve().parents[2] / "build/PS5 MCP.app"
NATIVE_BINARY = APP_BUNDLE / "Contents/MacOS/PS5 MCP"


class NativeApp:
    """The PS5 app (app/*.swift): capture card, the padd link, keyboard, and the local API on capture.sock."""

    def __init__(self, root: Path | None = None, binary: Path = NATIVE_BINARY):
        self.root = root or state_dir()
        self.binary = binary
        self.latest = self.root / "latest.jpg"
        self.log = self.root / "ps5-app.log"
        self.socket = self.root / "capture.sock"

    def request(self, cmd: str, timeout: float = 3.0, **fields) -> list[dict]:
        """Send one command; returns every reply line (watch_change answers twice)."""
        import json
        import socket as sk
        expected = 2 if cmd == "watch_change" else 1
        with sk.socket(sk.AF_UNIX, sk.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(str(self.socket))
            conn.sendall((json.dumps({"cmd": cmd, **fields}) + "\n").encode())
            data = b""
            while data.count(b"\n") < expected:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
        return [json.loads(line) for line in data.splitlines() if line]

    def status(self) -> dict | None:
        try:
            return self.request("status", timeout=1.0)[0]
        except OSError:
            return None

    def pid(self) -> int | None:
        status = self.status()
        return status["pid"] if status else None

    def frame_age(self) -> float | None:
        status = self.status()
        return status["frame_age"] if status and status["frame_age"] >= 0 else None

    @staticmethod
    def _check_host(status: dict, host: str | None) -> str | None:
        """Fail closed if a requested console does not match the app's live target."""
        pad = status.get("pad")
        target = pad.get("host") if isinstance(pad, dict) else None
        if not isinstance(target, str) or not target:
            target = None
        if host and target != host:
            actual = repr(target) if target else "an unknown console"
            raise CaptureError(f"PS5 app is targeting {actual}, but requested console is {host!r}. "
                               "Quit the app or change its console address in Settings before retrying.")
        return target

    def target_host(self, host: str | None = None) -> str:
        """The running app's console, validated against `host` or PS5_HOST when supplied.

        Settings can change the console while the app runs. Network operations outside the app must read this
        live target rather than independently defaulting to PS5_HOST.
        """
        status = self.status()
        if status is None:
            raise CaptureError("PS5 app is not running; cannot determine its console address")
        target = self._check_host(status, host or os.environ.get("PS5_HOST"))
        if not target:
            raise CaptureError("The PS5 app has no console address; set it in Settings or launch with PS5_HOST")
        return target

    def start(self, video: str | None = None, audio: str | None = DEFAULT_AUDIO, timeout: float = 10,
              visible: bool = False, host: str | None = None) -> int:
        """Launch the app unless it runs on the requested host; refuse a mismatched running app.

        PS5MCP_VIDEO=file:PATH or synthetic runs it without the card.

        With the card it is launched through `open`, so macOS asks for camera/microphone permission for the app
        itself rather than for the terminal that started it.
        """
        host = host or os.environ.get("PS5_HOST")
        if (status := self.status()) is not None:
            self._check_host(status, host)
            if visible:
                self.request("show")
            return status["pid"]
        if not self.binary.exists():
            raise CaptureError(f"{self.binary} missing; run make")
        video = video or os.environ.get("PS5MCP_VIDEO", DEFAULT_VIDEO)
        if video.startswith("file:") or video == "synthetic":
            audio = None
        args = ["--state-dir", str(self.root), "--video", video, "--audio", audio or "none"]
        if host:  # without it the app shows that the console address is missing
            args += ["--host", host]
        if not visible:
            args.append("--headless")
        bundle = self.binary.parents[2]
        if video.startswith("file:") or video == "synthetic" or bundle.suffix != ".app":
            with self.log.open("ab") as log:
                process = subprocess.Popen([str(self.binary), *args], stdin=subprocess.DEVNULL, stdout=log,
                                           stderr=log, start_new_session=True)
        else:
            subprocess.run(["open", "-n", "-g", "--stdout", str(self.log), "--stderr", str(self.log), str(bundle),
                            "--args", *args], check=True, timeout=10)
            process = None
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if process is not None and process.poll() is not None:
                raise CaptureError(f"PS5 app exited with {process.returncode}; see {self.log}")
            status = self.status()
            if status:
                self._check_host(status, host)
                if status["frames"] > 0:
                    return status["pid"]
            time.sleep(0.2)
        if process is None:
            # Launched through `open`: it may be waiting on the camera permission prompt. It is the user's app now.
            raise CaptureError("The PS5 app is running but has no frames yet. Allow camera access if macOS asks "
                               "(System Settings > Privacy & Security > Camera > PS5 MCP), and check the HDMI signal. "
                               f"See {self.log}")
        process.kill()
        raise CaptureError("No frame within timeout. Is another app (QuickTime, OBS, the ffmpeg daemon) holding "
                           f"the card, or was camera permission denied for the PS5 app? See {self.log}")

    def show(self) -> None:
        self.request("show")

    def stop(self, grace: float = 3) -> bool:
        pid = self.pid()
        if pid is None:
            return False
        try:
            self.request("quit")
        except OSError:
            pass
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            time.sleep(0.1)
        os.kill(pid, signal.SIGKILL)
        return True

    def refresh(self) -> None:
        self.request("snapshot")

    def watch_change(self, threshold: float = 6.0, timeout: float = 2.0) -> tuple[float, dict]:
        """Arm change detection; returns (armed_at, result). Times use the macOS uptime clock (time.monotonic)."""
        replies = self.request("watch_change", timeout=timeout + 2, threshold=threshold, timeout_s=timeout)
        return replies[0]["armed_at"], replies[-1]


def backend(root: Path | None = None) -> Daemon | NativeApp:
    """The native app when built, unless PS5MCP_CAPTURE=ffmpeg; whichever is already running wins."""
    native, ffmpeg = NativeApp(root), Daemon(root)
    if native.status() is not None:
        return native
    if ffmpeg.pid() is not None:
        return ffmpeg
    if os.environ.get("PS5MCP_CAPTURE", "native") == "ffmpeg" or not native.binary.exists():
        return ffmpeg
    return native


def grab_direct(destination: Path, video: str = DEFAULT_VIDEO, timeout: float = 10) -> None:
    """Open the device for one frame. Fails if the daemon (or anything else) holds it."""
    # The first frames after opening can be dark while the card locks the signal.
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", *_input_args(video, None),
               "-vf", "select=gte(n\\,10)", "-frames:v", "1", "-update", "1", "-y", str(destination)]
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        _, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise CaptureError("Timed out waiting for a frame (device busy or no camera permission)") from None
    if process.returncode != 0 or not destination.exists():
        raise CaptureError(stderr.decode(errors="replace").strip() or "ffmpeg failed")


def snapshot(destination: Path, max_width: int | None = None, daemon: Daemon | NativeApp | None = None) -> Path:
    """Save the current frame as JPEG or PNG (by extension), optionally scaled down."""
    daemon = daemon or backend()
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        if daemon.pid() is not None:
            age = daemon.frame_age()
            if age is None or age > MAX_FRAME_AGE:
                raise CaptureError(f"Capture daemon is running but its latest frame is stale ({age}s)")
            daemon.refresh()
            source = Path(scratch) / "frame.jpg"
            shutil.copyfile(daemon.latest, source)
        else:
            source = Path(scratch) / "frame.png"
            grab_direct(source)
        if max_width is None and source.suffix == destination.suffix:
            shutil.copyfile(source, destination)
        else:
            scale = ["-vf", f"scale='min({max_width},iw)':-2"] if max_width else []
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(source),
                            *scale, "-q:v", "2", "-y", str(destination)], check=True, timeout=15)
    return destination


def mean_luma(path: Path) -> float:
    """Average brightness 0-255; near zero means a black frame (often HDCP)."""
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path),
                          "-vf", "scale=64:36,format=gray", "-f", "rawvideo", "-"],
                         capture_output=True, check=True, timeout=15).stdout
    return sum(raw) / len(raw) if raw else 0.0
