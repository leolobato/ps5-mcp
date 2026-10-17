"""Dependency integrity checks without downloading or contacting a console."""
import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest


def load_script(name):
    path = Path(__file__).resolve().parents[1] / "scripts" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(path.parent))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return module


def test_corrupt_cached_download_is_rejected_before_extraction(tmp_path):
    bootstrap = load_script("bootstrap.py")
    cached = tmp_path / "example.tar.gz"
    cached.write_bytes(b"corrupted download")
    entry = {"url": "https://invalid.example/example.tar.gz", "sha256": hashlib.sha256(b"original").hexdigest()}
    with pytest.raises(SystemExit, match="checksum mismatch"):
        bootstrap.fetch_archive(entry, tmp_path)
    assert cached.read_bytes() == b"corrupted download"


def test_archive_cannot_write_outside_source_directory(tmp_path):
    bootstrap = load_script("bootstrap.py")
    archive = tmp_path / "unsafe.tar.gz"
    with tarfile.open(archive, "w:gz") as output:
        member = tarfile.TarInfo("../escaped")
        member.size = 7
        output.addfile(member, io.BytesIO(b"escaped"))
    with pytest.raises((ValueError, tarfile.FilterError)):
        bootstrap.extract_archive(archive, tmp_path / "source")
    assert not (tmp_path / "escaped").exists()


def test_existing_source_with_different_checksum_is_not_overwritten(tmp_path):
    bootstrap = load_script("bootstrap.py")
    destination = tmp_path / "source"
    destination.mkdir()
    (destination / ".ps5mcp-sha256").write_text("old checksum\n")
    entry = {"url": "https://invalid.example/absent.tar.gz", "sha256": "f" * 64}
    with pytest.raises(SystemExit, match="Unmanaged/different"):
        bootstrap.prepare_source(entry, tmp_path / "downloads", destination)
    assert (destination / ".ps5mcp-sha256").read_text() == "old checksum\n"


def test_build_config_has_per_architecture_static_link_inputs():
    script = Path(__file__).resolve().parents[1] / "scripts/build-remoteplay.py"
    result = subprocess.run([sys.executable, str(script), "--arch", "x86_64", "--config"],
                            capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr
    config = json.loads(result.stdout)
    assert config["architecture"] == "x86_64"
    assert config["deployment_target"] == "14.0"
    assert config["libraries"]
    assert all(Path(p).suffix == ".a" for p in config["libraries"])
    assert all(".deps/remoteplay/x86_64/" in p for p in config["libraries"])
    assert config["frameworks"] == ["CoreServices", "SystemConfiguration"]


def test_unsupported_architecture_is_rejected():
    script = Path(__file__).resolve().parents[1] / "scripts/build-remoteplay.py"
    result = subprocess.run([sys.executable, str(script), "--arch", "i386", "--config"],
                            capture_output=True, text=True, check=False)
    assert result.returncode != 0
    assert "invalid choice" in result.stderr


def test_ambient_host_linker_and_header_flags_do_not_contaminate_build(monkeypatch):
    builder = load_script("build-remoteplay.py")
    monkeypatch.setenv("LDFLAGS", "-L/opt/homebrew/lib -lssl")
    monkeypatch.setenv("CPATH", "/usr/local/include")
    monkeypatch.setenv("CFLAGS", "-march=native")
    env = builder.clean_environment()
    assert "LDFLAGS" not in env
    assert "CPATH" not in env
    assert "CFLAGS" not in env
    assert env["PATH"]


def test_modified_checkout_cannot_be_reported_as_the_pinned_source(tmp_path):
    bootstrap = load_script("bootstrap.py")
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    tracked = tmp_path / "core.c"
    tracked.write_text("pinned source\n")
    subprocess.run(["git", "add", "core.c"], cwd=tmp_path, check=True)
    subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                    "commit", "-qm", "fixture"], cwd=tmp_path, check=True)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=tmp_path, text=True).strip()
    tracked.write_text("locally modified source\n")
    with pytest.raises(SystemExit, match="modified"):
        bootstrap.verify_checkout(tmp_path, revision)
