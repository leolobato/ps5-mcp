"""Exercise the real credential validation and storage orchestration without a user's Keychain."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_remoteplay_credentials(tmp_path):
    binary = tmp_path / "credentials-tests"
    compiled = subprocess.run([
        "swiftc", str(ROOT / "app/RemotePlayCredentials.swift"),
        str(ROOT / "tests/native/RemotePlayCredentialsTests.swift"),
        "-framework", "Security", "-o", str(binary),
    ], capture_output=True, text=True, check=False)
    assert compiled.returncode == 0, compiled.stderr
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
    assert "credential checks passed" in result.stdout
