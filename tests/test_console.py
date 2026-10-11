"""Console services (Payload Manager, Web File Manager) that cannot be reached are named, with what to do."""

from __future__ import annotations

import errno
import io
import sys
import urllib.error
from types import SimpleNamespace

import pytest

from ps5mcp import probe_runner
from ps5mcp.probe_runner import Console, ConsoleError


def failing(reason: BaseException):
    def request(self, port, *args, **kwargs):
        raise probe_runner.unreachable(self.host, port, urllib.error.URLError(reason))
    return request


def raising(error: BaseException):
    def open_(*args, **kwargs):
        raise error
    return open_


def refused() -> OSError:
    return ConnectionRefusedError(errno.ECONNREFUSED, "Connection refused")


def no_route() -> OSError:
    return OSError(errno.EHOSTUNREACH, "No route to host")


def test_refused_service_is_named_with_how_to_start_it(monkeypatch):
    console = Console("ps5")
    monkeypatch.setattr(console.opener, "open", raising(urllib.error.URLError(refused())))
    with pytest.raises(ConsoleError, match=r"PS5 Web File Manager is not running on ps5:8888; start it \(Payload"):
        console.listdir("/user/app")
    with pytest.raises(ConsoleError, match="Payload Manager is not running on ps5:8084"):
        console.request(8084, "/version", method="GET")


def test_no_route_points_at_local_network_privacy_for_this_python(monkeypatch):
    console = Console("ps5")
    monkeypatch.setattr(console.opener, "open", raising(urllib.error.URLError(no_route())))
    with pytest.raises(ConsoleError) as caught:
        console.request(8084, "/upload")
    assert "Payload Manager at ps5:8084: no route to host" in str(caught.value)
    assert "Local Network" in str(caught.value) and sys.executable in str(caught.value)


def test_http_errors_still_come_from_the_service(monkeypatch):
    console = Console("ps5")
    error = urllib.error.HTTPError("http://ps5:8084/x", 500, "boom", {}, io.BytesIO(b""))
    monkeypatch.setattr(console.opener, "open", raising(error))
    with pytest.raises(urllib.error.HTTPError):
        console.request(8084, "/x")


async def test_list_apps_names_the_missing_web_file_manager(monkeypatch):
    from ps5mcp import server
    monkeypatch.setattr(server, "HOST", "ps5")
    monkeypatch.setattr(Console, "request", failing(refused()))
    result = await server.mcp.call_tool("list_apps", {})
    blocks = result.content if hasattr(result, "content") else result
    assert blocks[0].text == ("error: PS5 Web File Manager is not running on ps5:8888; "
                              "start it (Payload Manager can load it)")


def test_padd_start_checks_web_file_manager_first(monkeypatch):
    from ps5mcp import padd_runner

    def request(self, port, path, *args, **kwargs):
        if port == 8888:
            raise probe_runner.unreachable(self.host, port, urllib.error.URLError(refused()))
        return b"0.5.2"
    monkeypatch.setattr(Console, "request", request)
    with pytest.raises(SystemExit, match="PS5 Web File Manager is not running on ps5:8888"):
        padd_runner.preflight("ps5")


def test_padd_start_through_the_app_shows_why_it_failed(capsys):
    from ps5mcp import cli

    class App:
        def __init__(self, reply):
            self.reply = reply

        def request(self, cmd, **fields):
            return [self.reply]

        def close(self):
            pass

    args = SimpleNamespace(action="start", firmware="13.60")
    output = "padd start needs Payload Manager (8084) and PS5 Web File Manager (8888): ..."
    assert cli._padd_via_app(App({"ok": False, "action": "start", "exit": 1, "output": output}), args) == 1
    assert capsys.readouterr().out.strip() == output
    assert cli._padd_via_app(App({"ok": False, "error": "padd stop is already running", "code": "padd_busy"}),
                             args) == 1
    assert capsys.readouterr().out.strip() == "padd start through the PS5 app failed: padd stop is already running"
