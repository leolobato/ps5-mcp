"""Template matching, recordings and the MJPEG stream (host only)."""

from __future__ import annotations

import io
import threading
import urllib.request
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from ps5mcp import protocol as p
from ps5mcp import recording, stream, vision
from ps5mcp.protocol import PadState

ROOT = Path(__file__).resolve().parents[1]
REAL_FRAME = ROOT / "tests/fixtures/home.png"


def noise_frame(seed=1) -> Image.Image:
    rng = np.random.default_rng(seed)
    return Image.fromarray(rng.integers(0, 255, (1080, 1920), dtype=np.uint8)).convert("RGB")


def test_template_is_found_where_it_was_cut(tmp_path):
    frame = noise_frame()
    vision.save_template(tmp_path, "patch", frame, 800, 400, 160, 96)
    template, meta = vision.load_template(tmp_path, "patch")
    found = vision.match(vision.gray(frame), template)
    assert found.score > 0.99 and abs(found.x - 800) <= 4 and abs(found.y - 400) <= 4
    assert meta == {"x": 800, "y": 400, "width": 160, "height": 96}
    assert vision.match(vision.gray(noise_frame(2)), template).score < 0.5
    assert vision.list_templates(tmp_path) == ["patch"]


@pytest.mark.skipif(not REAL_FRAME.exists(), reason="test fixtures not present")
def test_template_on_a_real_ps5_frame(tmp_path):
    frame = Image.open(REAL_FRAME).convert("RGB")
    vision.save_template(tmp_path, "settings", frame, 1470, 20, 100, 110)  # the Settings gear, focused
    template, _ = vision.load_template(tmp_path, "settings")
    found = vision.match(vision.gray(frame), template)
    assert found.score > 0.99 and abs(found.x - 1470) <= 4


def test_template_validation(tmp_path):
    with pytest.raises(ValueError, match="names"):
        vision.save_template(tmp_path, "../x", noise_frame(), 0, 0, 32, 32)
    with pytest.raises(ValueError, match="outside"):
        vision.save_template(tmp_path, "edge", noise_frame(), 1900, 0, 64, 64)
    with pytest.raises(ValueError, match="no template"):
        vision.load_template(tmp_path, "missing")


def test_recorder_turns_changes_into_timed_steps():
    rec = recording.Recorder(started=0.0)
    rec.note(PadState(), at=0.0)
    rec.note(PadState(buttons=p.BUTTONS["right"]), at=1.0)   # 1 s idle before: trimmed
    rec.note(PadState(), at=1.08)
    rec.note(PadState(lx=0, r2=255), at=1.5)
    rec.note(PadState(), at=13.5)                             # 12 s hold: split into 10 s + 2 s
    steps = rec.steps(end=14.0)
    assert steps == [{"duration_ms": 80, "buttons": ["right"]}, {"duration_ms": 420},
                     {"duration_ms": 10000, "lx": -1.0039, "r2": 1.0}, {"duration_ms": 2000, "lx": -1.0039, "r2": 1.0}]
    assert recording.step_to_state(steps[2]) == PadState(lx=0, r2=255)
    assert recording.Recorder().steps() == []


def test_step_state_roundtrip_is_exact_for_every_axis_value():
    for value in range(256):
        state = PadState(lx=value, ry=value, l2=value)
        assert recording.step_to_state(recording.state_to_step(state, 10)) == state


def test_recordings_save_and_list(tmp_path):
    recording.save(tmp_path, "menu", [{"duration_ms": 80, "buttons": ["cross"]}], source="test")
    assert recording.load(tmp_path, "menu") == [{"duration_ms": 80, "buttons": ["cross"]}]
    assert recording.list_recordings(tmp_path) == [{"name": "menu", "duration_ms": 80, "steps": 1, "source": "test"}]


def test_mjpeg_stream_serves_page_snapshot_and_frames():
    jpeg = io.BytesIO()
    noise_frame().resize((320, 180)).save(jpeg, "JPEG")
    server = stream.make_server("127.0.0.1", 0, lambda: jpeg.getvalue(), fps=30)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        assert b"/stream.mjpg" in opener.open(base + "/").read()
        assert opener.open(base + "/snapshot.jpg").read() == jpeg.getvalue()
        with opener.open(base + "/stream.mjpg") as response:
            assert response.headers["Content-Type"].startswith("multipart/x-mixed-replace")
            data = b""
            while data.count(b"--ps5mcpframe") < 3:
                data += response.read1(65536)
        assert data.count(jpeg.getvalue()) >= 2
    finally:
        server.shutdown()
