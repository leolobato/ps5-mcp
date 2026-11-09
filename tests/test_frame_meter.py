"""The frame meter's rules, fed frame patterns with known answers."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_frame_meter(tmp_path):
    binary = tmp_path / "frame-meter-tests"
    compiled = subprocess.run([
        "swiftc", str(ROOT / "app/FrameDiff.swift"), str(ROOT / "app/FrameMeter.swift"),
        str(ROOT / "tests/native/FrameMeterTests.swift"), "-parse-as-library", "-framework", "CoreVideo", "-o", str(binary),
    ], check=False, capture_output=True, text=True)
    assert compiled.returncode == 0, compiled.stderr
    result = subprocess.run([str(binary)], check=False, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    assert "frame meter checks passed" in result.stdout


def test_recorder_writes_the_meter_csv(tmp_path):
    binary = tmp_path / "recorder-tests"
    compiled = subprocess.run([
        "swiftc", str(ROOT / "app/Video.swift"), str(ROOT / "app/FrameDiff.swift"), str(ROOT / "app/FrameMeter.swift"),
        str(ROOT / "tests/native/VideoRecorderMeterTests.swift"), "-parse-as-library", "-framework", "AVFoundation",
        "-o", str(binary),
    ], check=False, capture_output=True, text=True)
    assert compiled.returncode == 0, compiled.stderr
    result = subprocess.run([str(binary), str(tmp_path)], check=False, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    assert "recorder meter checks passed" in result.stdout


def test_snapshot_composite_draws_the_meter(tmp_path):
    binary = tmp_path / "overlay-tests"
    compiled = subprocess.run([
        "swiftc", str(ROOT / "app/FrameDiff.swift"), str(ROOT / "app/FrameMeter.swift"), str(ROOT / "app/FrameMeterOverlay.swift"),
        str(ROOT / "tests/native/FrameMeterOverlayTests.swift"), "-parse-as-library", "-framework", "AppKit", "-o", str(binary),
    ], check=False, capture_output=True, text=True)
    assert compiled.returncode == 0, compiled.stderr
    result = subprocess.run([str(binary)], check=False, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    assert "frame meter overlay checks passed" in result.stdout
