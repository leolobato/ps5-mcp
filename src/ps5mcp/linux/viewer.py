"""Loopback-only MJPEG fanout from immutable cached frames; never opens a device."""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ..capture import CaptureError

PAGE = b'''<!doctype html><html><head><meta name="viewport" content="width=device-width">
<title>PS5 MCP live video</title><style>body{margin:0;background:#111;color:white}
img{width:100vw;height:100vh;object-fit:contain}</style></head>
<body><img id="video" src="/stream.mjpg" alt="Live PS5 capture"><script>
const video=document.getElementById('video');
let lost=false;
video.onerror=()=>{lost=true;};
setInterval(async()=>{
 try {const s=await (await fetch('/status.json',{cache:'no-store'})).json();
  if(s.capture_error){lost=true;}
  else if(lost){lost=false;video.src='/stream.mjpg?t='+Date.now();}
 } catch(e){lost=true;}
},1000);
</script></body></html>'''


def metadata(frame):
    return {"frame_sequence": frame.sequence, "frame_timestamp": frame.monotonic,
            "frame_timestamp_unix": frame.unix}


def start_viewer(frame_source, status, stopped, port=0):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(2)

        def log_message(self, *_):
            pass

        def reply(self, code, kind, data, headers=None):
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            for name, value in (headers or {}).items():
                self.send_header(name, str(value))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            streaming = False
            try:
                path = self.path.split("?", 1)[0]
                if path == "/":
                    self.reply(200, "text/html; charset=utf-8", PAGE)
                elif path == "/status.json":
                    self.reply(200, "application/json", json.dumps(status()).encode())
                elif path == "/snapshot.jpg":
                    frame = frame_source()
                    self.reply(200, "image/jpeg", frame.jpeg, {
                        "X-Frame-Sequence": frame.sequence, "X-Frame-Timestamp": frame.monotonic,
                        "X-Frame-Timestamp-Unix": frame.unix})
                elif path == "/stream.mjpg":
                    frame = frame_source()  # Refuse unavailable capture before sending HTTP 200.
                    self.send_response(200)
                    self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=ps5frame")
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    streaming = True
                    sequence = None
                    while not stopped.is_set():
                        if frame.sequence != sequence:
                            header = (f"--ps5frame\r\nContent-Type: image/jpeg\r\nContent-Length: {len(frame.jpeg)}\r\n"
                                      f"X-Frame-Sequence: {frame.sequence}\r\n"
                                      f"X-Frame-Timestamp: {frame.monotonic}\r\n"
                                      f"X-Frame-Timestamp-Unix: {frame.unix}\r\n\r\n").encode()
                            self.wfile.write(header + frame.jpeg + b"\r\n")
                            self.wfile.flush()
                            sequence = frame.sequence
                        if stopped.wait(0.01):
                            break
                        frame = frame_source()
                else:
                    self.reply(404, "text/plain", b"not found\n")
            except CaptureError as exc:
                if not streaming:
                    self.reply(503, "text/plain", f"{exc}\n".encode())
                # End a stream when video is lost; a reconnect must obtain a fresh frame.
            except (OSError, TimeoutError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05},
                              daemon=True, name="linux-mjpeg")
    thread.start()
    return server, thread
