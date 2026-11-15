"""Tests use isolated state and loopback services, never an inherited console endpoint."""
import ipaddress
import shutil
import socket
import tempfile
from pathlib import Path

import pytest


@pytest.fixture
def tmp_path():
    # Unix socket paths are limited to 104 bytes on macOS; pytest's own tmp_path there is often longer.
    path = Path(tempfile.mkdtemp(prefix="ps5t-", dir="/tmp")).resolve()
    yield path
    shutil.rmtree(path, ignore_errors=True)


@pytest.fixture(autouse=True)
def isolated_console_environment(monkeypatch, tmp_path):
    for name in ('PS5_HOST', 'PS5MCP_VIDEO', 'PS5MCP_VIDEO_FORMAT', 'PS5MCP_VIDEO_SIZE',
                 'PS5MCP_VIDEO_FPS', 'PS5MCP_VIDEO_STALE_S', 'PS5MCP_VIEWER_PORT',
                 'PS5MCP_PAD_PORT', 'PS5MCP_STREAM_PORT', 'PS5MCP_IN_APP'):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv('PS5MCP_ALLOW_CONSOLE', '0')
    monkeypatch.setenv('PS5MCP_STATE', str(tmp_path / 'isolated-state'))
    original_connect = socket.socket.connect
    original_connect_ex = socket.socket.connect_ex
    original_sendto = socket.socket.sendto

    def check(address):
        host = address[0]
        if host == 'localhost':
            return
        try:
            allowed = ipaddress.ip_address(host).is_loopback
        except ValueError:
            allowed = False
        if not allowed:
            pytest.fail(f'Tests may only connect to loopback, refused {address!r}')

    def connect(sock, address):
        if sock.family in (socket.AF_INET, socket.AF_INET6):
            check(address)
        return original_connect(sock, address)

    def connect_ex(sock, address):
        if sock.family in (socket.AF_INET, socket.AF_INET6):
            check(address)
        return original_connect_ex(sock, address)

    def sendto(sock, data, *args):
        if sock.family in (socket.AF_INET, socket.AF_INET6):
            check(args[-1])
        return original_sendto(sock, data, *args)

    monkeypatch.setattr(socket.socket, 'sendto', sendto)
    monkeypatch.setattr(socket.socket, 'connect', connect)
    monkeypatch.setattr(socket.socket, 'connect_ex', connect_ex)
