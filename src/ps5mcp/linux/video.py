"""One FFmpeg input owner, bounded latest-frame storage, and restart supervision."""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import math
import os
import re
import selectors
import socket
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path

from ..capture import CaptureError

PBS_SOURCE = "pbs"

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
        if self.source == PBS_SOURCE or self.source.startswith("lavfi:"):
            return None
        return self.source.removeprefix("v4l2:")

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
        command = ["ffmpeg", "-hide_banner", "-loglevel", "warning"]
        if self.source == PBS_SOURCE:
            # The H.264 elementary stream arrives on stdin; decode each picture as soon as it is complete.
            # (-fflags nobuffer makes FFmpeg 8 drop every picture of this stream.)
            command += ["-flags", "low_delay", "-probesize", "32", "-analyzeduration", "0",
                        "-f", "h264", "-i", "pipe:0"]
        elif self.device:
            command += ["-nostdin", "-thread_queue_size", "2", "-f", "v4l2", "-input_format", self.input_format,
                        "-video_size", self.size, "-framerate", self.fps, "-i", self.device]
        else:
            command += ["-nostdin", "-re", "-f", "lavfi", "-i", self.source.removeprefix("lavfi:")]
        # UVC MJPEG is already independently decodable JPEG: avoid a lossy CPU round trip.
        codec = (["-c:v", "copy"] if self.device and self.input_format.lower() == "mjpeg"
                 else ["-c:v", "mjpeg", "-q:v", "3", "-threads", "1"])
        if self.source == PBS_SOURCE:
            # PBS sends limited-range YUV, which the MJPEG encoder refuses; JPEG is full range.
            codec = ["-vf", "scale=out_range=full,format=yuvj420p", *codec]
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
    # How long an attempt may take to deliver its first frame; after that, stale_s applies.
    startup_s = None

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

    def _launch(self):
        return subprocess.Popen(self.config.command(), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, bufsize=0)

    def _finish(self):
        """Runs after FFmpeg has been reaped, before the next attempt."""

    def _attempt(self):
        process = self._launch()
        with self.lock:
            self.process = process
            self.starts += 1
            self.error = "Waiting for a fresh FFmpeg frame"
        pending = bytearray()
        diagnostics = bytearray()
        last_frame = time.monotonic()
        limit = max(self.config.stale_s, self.startup_s or 0)
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
                            limit = self.config.stale_s
                    if process.poll() is not None and not selector.get_map():
                        reason = f"FFmpeg exited with status {process.returncode}"
                        break
                    if time.monotonic() - last_frame > limit:
                        reason = f"No fresh video for {limit:g}s (stale frame or disconnected device)"
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
            self._finish()
        if not self.stopped.is_set():
            reason = self._reason(reason)
            details = diagnostics.decode(errors="replace").strip()
            if "busy" in details.lower():
                reason = (f"Capture device {self.config.device} is busy. Close the application's physical-device "
                          "input and use this hub's MJPEG stream or a v4l2loopback virtual camera")
            elif "permission denied" in details.lower():
                reason = f"Permission denied opening {self.config.device}; check your video-device permissions"
            raise CaptureError(f"{reason}. {details}".strip())

    def _reason(self, reason):
        return reason


PBS_PORT = 9999
START_CODE = b"\x00\x00\x00\x01"
ACCESS_UNIT_DELIMITER = START_CODE + b"\x09\xf0"


def pbs_port_from_environment():
    try:
        port = int(os.environ.get("PS5MCP_PBS_PORT", PBS_PORT))
        if not 1 <= port <= 65535:
            raise ValueError
    except ValueError:
        raise CaptureError("PS5MCP_PBS_PORT must be 1..65535") from None
    return port


class PBSStream:
    """One HTTP/1.1 GET to the PBS payload over a blocking socket. `cancel` may run on another thread and
    unblocks a reader at once."""

    max_header = 16 * 1024
    read_s = 3.0

    def __init__(self, host, port, path, connect_s=2.0, read_s=None):
        self.sock = socket.create_connection((host, port), timeout=connect_s)
        self.sock.settimeout(read_s or self.read_s)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.pending = bytearray()
        try:
            self.sock.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n"
                              "Content-Length: 0\r\n\r\n".encode())
            while (end := self.pending.find(b"\r\n\r\n")) < 0:
                if len(self.pending) > self.max_header or not self._fill():
                    raise CaptureError(f"PBS at {host}:{port} sent no reply headers for {path}")
            status = bytes(self.pending[:end]).split(b"\r\n", 1)[0].split()
            del self.pending[:end + 4]
            if len(status) < 2 or status[1] != b"200":
                raise CaptureError(f"PBS at {host}:{port} answered {path} with {b' '.join(status[1:]).decode(errors='replace')}")
        except BaseException:
            self.close()
            raise

    def _fill(self):
        data = self.sock.recv(256 * 1024)
        self.pending.extend(data)
        return bool(data)

    def read(self, count):
        """Exactly `count` bytes, or None when the stream ends."""
        while len(self.pending) < count:
            if not self._fill():
                return None
        data = bytes(self.pending[:count])
        del self.pending[:count]
        return data

    def read_to_end(self, limit):
        while len(self.pending) <= limit and self._fill():
            pass
        if len(self.pending) > limit:
            raise CaptureError(f"PBS reply is larger than {limit} bytes")
        return bytes(self.pending)

    def read_packet(self, limit):
        """One media packet's payload: a big-endian length and timestamp, then the payload."""
        header = self.read(8)
        if header is None:
            return None
        length = int.from_bytes(header[:4], "big")
        if not 0 < length <= limit:
            raise CaptureError(f"PBS sent a {length}-byte packet (limit {limit})")
        return self.read(length)

    def cancel(self):
        with contextlib.suppress(OSError):
            self.sock.shutdown(socket.SHUT_RDWR)

    def close(self):
        self.cancel()
        self.sock.close()


def pbs_parameter_sets(config):
    """The SPS and PPS from PBS's /config.json, as Annex B NAL units."""
    try:
        sps, pps = bytes.fromhex(config["sps"]), bytes.fromhex(config["pps"])
    except (KeyError, TypeError, ValueError):
        raise CaptureError("PBS /config.json has no valid sps and pps") from None
    if not sps or not pps:
        raise CaptureError("PBS /config.json has no valid sps and pps")
    return START_CODE + sps + START_CODE + pps


class PBSCapture(FFmpegCapture):
    """Video from the PBS payload's HTTP service (seregonwar/PBS-Payload), decoded by FFmpeg into the same
    latest-frame cache as a capture card. Audio is not read. A reader thread copies H.264 packets from
    PBS into FFmpeg's stdin; when PBS goes away FFmpeg's input ends and the usual retry loop reconnects."""

    max_packet = 8 * 1024 * 1024
    # A new PBS stream begins at the encoder's next IDR, which was seen to take over 3 s.
    startup_s = 10.0

    def __init__(self, config: VideoConfig, latest: Path, host: str, port: int = PBS_PORT):
        super().__init__(config, latest)
        self.host, self.port = host, port
        self.error = f"Connecting to PBS at {host}:{port}"
        self.stream = None
        self.feeder = None
        self.stream_error = None
        self.parameters = None

    def info(self):
        info = super().info()
        info["pbs"] = {"host": self.host, "port": self.port, "size": self.parameters}
        return info

    def _waiting(self, detail):
        return (f"Waiting for PBS at {self.host}:{self.port} ({detail}). Load the PBS payload on the console: "
                "ps5mcp get-pbs --run")

    def _launch(self):
        try:
            with contextlib.closing(PBSStream(self.host, self.port, "/config.json")) as reply:
                config = json.loads(reply.read_to_end(64 * 1024))
            if not isinstance(config, dict):
                raise CaptureError("PBS /config.json is not an object")
            parameters = pbs_parameter_sets(config)
            self.parameters = (f"{config['width']}x{config['height']}"
                               if isinstance(config.get("width"), int) and isinstance(config.get("height"), int)
                               else None)
            stream = PBSStream(self.host, self.port, "/frames", read_s=self.startup_s)
        except (OSError, ValueError) as exc:
            raise CaptureError(self._waiting(str(exc) or type(exc).__name__)) from None
        try:
            process = subprocess.Popen(self.config.command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, bufsize=0)
        except BaseException:
            stream.close()
            raise
        self.stream, self.stream_error = stream, None
        self.feeder = threading.Thread(target=self._feed, args=(stream, process.stdin, parameters),
                                       daemon=True, name="pbs-reader")
        self.feeder.start()
        return process

    def _feed(self, stream, sink, parameters):
        error = "PBS closed the video stream"
        try:
            sink.write(parameters)
            first = True
            while not self.stopped.is_set():
                packet = stream.read_packet(self.max_packet)
                if packet is None:
                    break
                if first:  # waiting for the first IDR is over; a stall is now a lost stream
                    stream.sock.settimeout(PBSStream.read_s)
                    first = False
                # FFmpeg's parser ends a picture only when the next one starts: an access unit delimiter
                # after each packet lets it decode the newest picture now, even when the screen is still.
                sink.write(packet + ACCESS_UNIT_DELIMITER)
        except TimeoutError:
            error = "PBS stopped sending video"
        except (OSError, CaptureError) as exc:
            error = str(exc) or type(exc).__name__
        finally:
            self.stream_error = error
            with contextlib.suppress(OSError):
                sink.close()

    def _finish(self):
        if self.stream:
            self.stream.cancel()
        if self.feeder:
            self.feeder.join(timeout=5)
            self.feeder = None
        if self.stream:
            self.stream.close()
            self.stream = None

    def _reason(self, reason):
        return self._waiting(self.stream_error) if self.stream_error else reason
