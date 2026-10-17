"""Run the native setup HTTP client against an isolated URLProtocol fixture."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_remoteplay_setup(tmp_path):
    binary = tmp_path / "setup-tests"
    compiled = subprocess.run([
        "swiftc", str(ROOT / "app/RemotePlayCredentials.swift"),
        str(ROOT / "app/RemotePlaySetup.swift"),
        str(ROOT / "app/RemotePlayAdmission.swift"),
        str(ROOT / "tests/native/RemotePlaySetupTests.swift"),
        "-framework", "Security", "-o", str(binary),
    ], capture_output=True, text=True, check=False)
    assert compiled.returncode == 0, compiled.stderr
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
    assert "setup checks passed" in result.stdout
