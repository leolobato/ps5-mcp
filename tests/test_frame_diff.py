"""Compare real pixel buffers with the production frame differ, built as the app builds it."""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUDGET_US = 2000


def test_frame_diff(tmp_path):
    binary = tmp_path / "frame-diff-tests"
    compiled = subprocess.run([
        "swiftc", "-O", str(ROOT / "app/FrameDiff.swift"), str(ROOT / "tests/native/FrameDiffTests.swift"),
        "-framework", "CoreVideo", "-o", str(binary),
    ], check=False, capture_output=True, text=True)
    assert compiled.returncode == 0, compiled.stderr
    result = subprocess.run([str(binary)], check=False, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    match = re.search(r"frame diff checks passed; (\d+) us per frame", result.stdout)
    assert match, result.stdout
    assert int(match.group(1)) < BUDGET_US, result.stdout
