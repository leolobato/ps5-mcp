"""MJPEG stream of the capture card for humans (any browser, other machines on the LAN if bound there).

GET /             a page with the live image
GET /stream.mjpg  multipart/x-mixed-replace JPEG stream
GET /snapshot.jpg the current frame

Frames come from whichever capture backend is running, so the stream never opens the card itself.
The native window (`ps5mcp view`) stays the low-latency view; this is for watching from elsewhere.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import capture

PAGE = b"""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>PS5</title><style>html,body{margin:0;height:100%;background:#000}
img{display:block;width:100vw;height:100vh;object-fit:contain}</style></head>
<body><img src="/stream.mjpg" alt="PS5 live"></body></html>"""
BOUNDARY = b"ps5mcpframe"


def backend_frames(backend=None) -> Callable[[], bytes]:
    backend = backend or capture.backend()

    def frame() -> bytes:
        if backend.pid() is None:
            raise capture.CaptureError("capture is not running; `ps5mcp capture start`")
        backend.refresh()
        return backend.latest.read_bytes()
    return frame


def make_server(bind: str, port: int, frames: Callable[[], bytes], fps: float = 10.0) -> ThreadingHTTPServer:
    interval = 1.0 / max(0.5, min(fps, 30.0))

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def _send(self, status: int, kind: str, body: bytes) -> None:
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?")[0]
            try:
                if path == "/":
                    self._send(200, "text/html; charset=utf-8", PAGE)
                elif path == "/snapshot.jpg":
                    self._send(200, "image/jpeg", frames())
                elif path == "/stream.mjpg":
                    self.send_response(200)
                    self.send_header("Content-Type", f"multipart/x-mixed-replace; boundary={BOUNDARY.decode()}")
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    while True:
                        started = time.monotonic()
                        data = frames()
                        self.wfile.write(b"--" + BOUNDARY + b"\r\nContent-Type: image/jpeg\r\nContent-Length: "
                                         + str(len(data)).encode() + b"\r\n\r\n" + data + b"\r\n")
                        self.wfile.flush()
                        time.sleep(max(0.0, interval - (time.monotonic() - started)))
                else:
                    self._send(404, "text/plain", b"not found\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            except capture.CaptureError as exc:
                self._send(503, "text/plain", f"{exc}\n".encode())

    server = ThreadingHTTPServer((bind, port), Handler)
    server.daemon_threads = True
    return server


def serve_in_background(bind: str, port: int, fps: float = 10.0, frames=None) -> ThreadingHTTPServer:
    server = make_server(bind, port, frames or backend_frames(), fps)
    threading.Thread(target=server.serve_forever, daemon=True, name="mjpeg").start()
    return server
