"""Decode actual Annex B video and package PCM through the production media classes."""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def test_remoteplay_media(tmp_path):
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        pytest.skip("ffmpeg is required to generate H.264 decoder fixtures")
    fixtures = []
    for name, size, color in [("red720", "1280x720", "red"), ("blue1080", "1920x1080", "blue")]:
        fixture = tmp_path / f"{name}.h264"
        subprocess.run([
            ffmpeg, "-v", "error", "-f", "lavfi", "-i", f"color=c={color}:s={size}:r=60",
            "-frames:v", "1", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
            "-pix_fmt", "yuv420p", "-x264-params", "keyint=1:repeat-headers=1", "-f", "h264", str(fixture),
        ], check=True, capture_output=True, text=True)
        fixtures.append(str(fixture))
    dependent = tmp_path / "dependent.h264"
    subprocess.run([
        ffmpeg, "-v", "error", "-f", "lavfi", "-i", "color=c=green:s=1280x720:r=60",
        "-frames:v", "2", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-pix_fmt", "yuv420p", "-x264-params", "keyint=60:repeat-headers=1:aud=1",
        "-f", "h264", str(dependent),
    ], check=True, capture_output=True, text=True)
    fixtures.append(str(dependent))
    binary = tmp_path / "media-tests"
    compiled = subprocess.run([
        "swiftc", str(ROOT / "app/RemotePlayDecoder.swift"), str(ROOT / "app/RemotePlayAudio.swift"),
        str(ROOT / "tests/native/RemotePlayMediaTests.swift"), "-framework", "VideoToolbox",
        "-framework", "AVFoundation", "-framework", "CoreImage", "-o", str(binary),
    ], check=False, capture_output=True, text=True)
    assert compiled.returncode == 0, compiled.stderr
    result = subprocess.run([str(binary), *fixtures], check=False, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    assert "media checks passed" in result.stdout
