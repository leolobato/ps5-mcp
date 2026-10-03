"""Input-to-capture latency: press D-pad right/left through padd, time the first changed captured frame.

Measures Mac -> PS5 app -> padd -> PS5 UI -> HDMI -> capture card -> the app's frame callback. Display latency of
the window (about one refresh) is not included. Needs the PS5 app running with its padd link up.
"""

from __future__ import annotations

import json
import statistics
import threading
import time
from datetime import UTC, datetime

from . import capture, hub
from . import protocol as p
from .probe_runner import ROOT


def run(host: str, samples: int = 10) -> int:
    app = capture.NativeApp()
    status = app.status()
    if not status:
        raise SystemExit("the PS5 app is not running; `ps5mcp view` first")
    skew = time.monotonic() - status["now"]
    if abs(skew) > 0.05:
        raise SystemExit(f"capture clock differs from time.monotonic by {skew:.3f}s; cannot time frames")
    link = hub.AppClient(app.socket, client="latency")
    link.call("status", wait=3.0)
    results = []
    try:
        for i in range(samples):
            button = "right" if i % 2 == 0 else "left"  # alternate so the UI ends where it started
            reply: dict = {}
            watcher = threading.Thread(target=lambda out=reply: out.update(app.watch_change(threshold=4.0, timeout=1.5)[1]))
            watcher.start()
            time.sleep(0.15)  # let the next frame become the reference
            pressed_at = time.monotonic()
            link.set(p.PadState(buttons=p.BUTTONS[button]), wait=1.0)
            time.sleep(0.08)
            link.set(p.PadState())
            watcher.join()
            if reply.get("ok"):
                results.append({"button": button, "latency_ms": round((reply["changed_at"] - pressed_at) * 1000, 1),
                                "diff": round(reply["diff"], 1)})
            else:
                results.append({"button": button, "latency_ms": None})
            time.sleep(0.6)
    finally:
        link.close()  # releases this client's input
    values = [r["latency_ms"] for r in results if r["latency_ms"] is not None]
    summary = {"recorded_at": datetime.now(UTC).isoformat(), "console": host, "samples": results,
               "measured": len(values), "clock_skew_s": round(skew, 4),
               "path": "Mac -> PS5 app -> padd -> PS5 UI -> HDMI -> capture card -> PS5 app frame callback"}
    if values:
        summary.update(median_ms=statistics.median(values), min_ms=min(values), max_ms=max(values))
    out = ROOT / "results" / (datetime.now(UTC).strftime("%Y%m%dT%H%M%S.%fZ") + "-latency")
    out.mkdir(parents=True)
    (out / "latency.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "samples"}, indent=2))
    print(f"recorded: {out.relative_to(ROOT)}")
    return 0 if values else 1
