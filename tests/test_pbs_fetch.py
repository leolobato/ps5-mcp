"""Fetching the pinned PBS release: only a copy with the pinned SHA256 is ever kept or installed."""

import hashlib
import io

import pytest

from ps5mcp import cli, pbs


def _serve(monkeypatch, body: bytes) -> list[str]:
    urls: list[str] = []

    def urlopen(url, timeout):
        urls.append(url)
        return io.BytesIO(body)

    monkeypatch.setattr(pbs.urllib.request, "urlopen", urlopen)
    return urls


def test_pin_is_an_https_upstream_release():
    assert pbs.URL.startswith("https://github.com/seregonwar/PBS-Payload/releases/download/v")
    assert pbs.URL.endswith("/" + pbs.NAME) and len(pbs.SHA256) == 64


def test_downloads_and_keeps_a_matching_copy(tmp_path, monkeypatch):
    body = b"\x7fELF pbs"
    urls = _serve(monkeypatch, body)
    path = pbs.fetch(tmp_path, sha256=hashlib.sha256(body).hexdigest())
    assert path == tmp_path / pbs.NAME and path.read_bytes() == body and urls == [pbs.URL]
    # A second fetch reuses the cached copy.
    assert pbs.fetch(tmp_path, sha256=hashlib.sha256(body).hexdigest()) == path and len(urls) == 1


def test_rejects_a_wrong_hash_and_leaves_nothing(tmp_path, monkeypatch):
    _serve(monkeypatch, b"tampered")
    with pytest.raises(RuntimeError, match="expected"):
        pbs.fetch(tmp_path, sha256="0" * 64)
    assert list(tmp_path.iterdir()) == []


def test_replaces_a_cached_copy_with_the_wrong_hash(tmp_path, monkeypatch):
    body = b"\x7fELF good"
    (tmp_path / pbs.NAME).write_bytes(b"stale")
    urls = _serve(monkeypatch, body)
    path = pbs.fetch(tmp_path, sha256=hashlib.sha256(body).hexdigest())
    assert path.read_bytes() == body and len(urls) == 1


def test_cli_reports_a_failed_download_as_an_install_failure(monkeypatch, capsys):
    monkeypatch.setattr(pbs, "fetch", lambda: (_ for _ in ()).throw(RuntimeError("offline")))
    monkeypatch.setenv("PS5_HOST", "192.0.2.1")
    assert cli.main(["get-pbs"]) == 1
    assert capsys.readouterr().out.splitlines()[-1] == "install failed: offline"
