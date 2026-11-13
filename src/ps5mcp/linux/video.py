"""One FFmpeg input owner, bounded latest-frame storage, and restart supervision."""
from __future__ import annotations

import fcntl
import hashlib
import math
import os
import re
import selectors
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path

from ..capture import CaptureError


@dataclass(frozen=True)
class VideoConfig:
    source: str
    input_format: str | None = None
    size: str | None = None
    fps: str | None = None
    stale_s: float = 2.0
    retry_s: float = 1.0

    @classmethod
    def environment(cls, source):
        return cls(source, os.environ.get("PS5MCP_VIDEO_FORMAT"), os.environ.get("PS5MCP_VIDEO_SIZE"),
                   os.environ.get("PS5MCP_VIDEO_FPS"), float(os.environ.get("PS5MCP_VIDEO_STALE_S", "2")))

    @property
    def device(self):
        return self.source.removeprefix("v4l2:") if not self.source.startswith("lavfi:") else None

    def validate(self):
        if not math.isfinite(self.stale_s) or not 0.1 <= self.stale_s <= 60:
            raise CaptureError("PS5MCP_VIDEO_STALE_S must be 0.1..60 seconds")
        if not math.isfinite(self.retry_s) or not 0.05 <= self.retry_s <= 30:
            raise CaptureError("Capture retry interval must be 0.05..30 seconds")
        if self.device is not None:
            if not self.device.startswith("/dev/"):
                raise CaptureError("V4L2 requires an explicit /dev/videoN or /dev/v4l/by-id/... device")
            if not all((self.input_format, self.size, self.fps)):
                raise CaptureError("V4L2 requires explicit VIDEO_FORMAT, VIDEO_SIZE and VIDEO_FPS "
                                   "(PS5MCP_ environment variables or capture start flags)")
        if self.size and not re.fullmatch(r"[1-9]\d{0,4}x[1-9]\d{0,4}", self.size):
            raise CaptureError("Video size must be WIDTHxHEIGHT")
        if self.input_format and not re.fullmatch(r"[a-zA-Z0-9_]+", self.input_format):
            raise CaptureError("Invalid V4L2 input format")
        if self.fps:
            try:
                rate = Fraction(self.fps)
                if not 0 < rate <= 240:
                    raise ValueError
            except (ValueError, ZeroDivisionError):
                raise CaptureError("Video FPS must be 0..240 (exclusive of zero); fractions are supported") from None

    def command(self):
        self.validate()
        command = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostdin"]
        if self.device:
            command += ["-thread_queue_size", "2", "-f", "v4l2", "-input_format", self.input_format,
                        "-video_size", self.size, "-framerate", self.fps, "-i", self.device]
        else:
            command += ["-re", "-f", "lavfi", "-i", self.source.removeprefix("lavfi:")]
        # UVC MJPEG is already independently decodable JPEG: avoid a lossy CPU round trip.
        codec = (["-c:v", "copy"] if self.device and self.input_format.lower() == "mjpeg"
                 else ["-c:v", "mjpeg", "-q:v", "3", "-threads", "1"])
        return command + ["-map", "0:v:0", "-an", *codec, "-fps_mode", "passthrough",
                          "-f", "image2pipe", "-flush_packets", "1", "pipe:1"]


def device_lock(device):
    """Cross-checkout lock, keyed by canonical path; never delete a live flock inode."""
    directory = Path(tempfile.gettempdir()) / f"ps5mcp-video-{os.getuid()}"
    directory.mkdir(mode=0o700, exist_ok=True)
    key = hashlib.sha256(os.fsencode(Path(device).resolve())).hexdigest()
    handle = (directory / f"{key}.lock").open("a")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise CaptureError(f"{device} is already owned by another PS5 MCP hub. "
                           "Use that hub's state directory or MJPEG viewer") from None
    return handle


@dataclass(frozen=True)
class Frame:
    jpeg: bytes
    sequence: int
    monotonic: float
    unix: float


class FFmpegCapture:
    def __init__(self, config: VideoConfig, latest: Path):
        config.validate()
        self.config, self.latest = config, latest
        self.lock = threading.Lock()
        self.frame = None
        self.error = "Waiting for the first FFmpeg frame"
        self.starts = 0
        self.process = None
        self.stopped = threading.Event()
        self.thread = None
        self._device_lock = None

    def start(self):
        if self.thread is not None:
            return
        if self.config.device:
            self._device_lock = device_lock(self.config.device)
        self.thread = threading.Thread(target=self._run, daemon=True, name="ffmpeg-capture")
        self.thread.start()

    def stop(self):
        self.stopped.set()
        if self.thread:
            self.thread.join(timeout=5)
            if self.thread.is_alive():
                raise CaptureError("FFmpeg capture worker did not stop")
        if self._device_lock:
            self._device_lock.close()
            self._device_lock = None

    def get(self):
        with self.lock:
            if self.error:
                raise CaptureError(self.error)
            frame = self.frame
            if frame is None or time.monotonic() - frame.monotonic > self.config.stale_s:
                raise CaptureError("Capture frame is stale; waiting for device recovery")
            return frame

    def info(self):
        with self.lock:
            frame = self.frame
            age = time.monotonic() - frame.monotonic if frame else None
            error = self.error
            if not error and (age is None or age > self.config.stale_s):
                error = "Capture frame is stale; waiting for device recovery"
            return {"frame_sequence": frame.sequence if frame else 0,
                    "frame_timestamp": frame.monotonic if frame else None,
                    "frame_timestamp_unix": frame.unix if frame else None,
                    "frame_age": age if age is not None else -1, "capture_error": error,
                    "ffmpeg_pid": self.process.pid if self.process and self.process.poll() is None else None,
                    "capture_starts": self.starts, "stale_after_s": self.config.stale_s}

    def _publish(self, data):
        # Disk publication completes before the metadata changes. Readers keep one immutable frame.
        temporary = self.latest.with_suffix(".tmp")
        temporary.write_bytes(data)
        temporary.replace(self.latest)
        with self.lock:
            sequence = self.frame.sequence + 1 if self.frame else 1
            self.frame = Frame(data, sequence, time.monotonic(), time.time())
            self.error = None

    def _run(self):
        while not self.stopped.is_set():
            try:
                self._attempt()
            except (OSError, CaptureError) as exc:
                with self.lock:
                    self.error = str(exc)
            if self.stopped.wait(self.config.retry_s):
                break

    def _attempt(self):
        process = subprocess.Popen(self.config.command(), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, bufsize=0)
        with self.lock:
            self.process = process
            self.starts += 1
            self.error = "Waiting for a fresh FFmpeg frame"
        pending = bytearray()
        diagnostics = bytearray()
        last_frame = time.monotonic()
        reason = "FFmpeg capture stopped"
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ, "video")
                selector.register(process.stderr, selectors.EVENT_READ, "error")
                while not self.stopped.is_set():
                    for key, _ in selector.select(timeout=0.05):
                        data = os.read(key.fileobj.fileno(), 65536)
                        if not data:
                            selector.unregister(key.fileobj)
                            continue
                        if key.data == "error":
                            diagnostics.extend(data)
                            del diagnostics[:-8192]
                            continue
                        pending.extend(data)
                        if len(pending) > 16 * 1024 * 1024:
                            raise CaptureError("FFmpeg frame exceeds 16 MiB limit")
                        while True:
                            start = pending.find(b"\xff\xd8")
                            end = pending.find(b"\xff\xd9", max(0, start + 2))
                            if start < 0 or end < 0:
                                break
                            self._publish(bytes(pending[start:end + 2]))
                            del pending[:end + 2]
                            last_frame = time.monotonic()
                    if process.poll() is not None and not selector.get_map():
                        reason = f"FFmpeg exited with status {process.returncode}"
                        break
                    if time.monotonic() - last_frame > self.config.stale_s:
                        reason = f"No fresh video for {self.config.stale_s:g}s (stale frame or disconnected device)"
                        break
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
            process.wait()
            process.stdout.close()
            process.stderr.close()
            with self.lock:
                self.process = None
        if not self.stopped.is_set():
            details = diagnostics.decode(errors="replace").strip()
            if "busy" in details.lower():
                reason = (f"Capture device {self.config.device} is busy. Close the application's physical-device "
                          "input and use this hub's MJPEG stream or a v4l2loopback virtual camera")
            elif "permission denied" in details.lower():
                reason = f"Permission denied opening {self.config.device}; check your video-device permissions"
            raise CaptureError(f"{reason}. {details}".strip())
