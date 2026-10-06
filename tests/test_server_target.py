"""Console target checks run without a macOS app or console hardware."""

from types import SimpleNamespace

import pytest

from ps5mcp import capture, installer, probe_runner, server, transfer


@pytest.fixture
def app_target(tmp_path, monkeypatch):
    monkeypatch.delenv("PS5_HOST", raising=False)
    monkeypatch.setattr(server, "HOST", None)
    current = {"pad": {"host": "192.0.2.20"}}
    native = capture.NativeApp(tmp_path)
    monkeypatch.setattr(native, "status", lambda: current)
    runtime = server.Runtime()
    runtime.capture = native
    runtime._app = SimpleNamespace(closed=False)
    monkeypatch.setattr(server, "runtime", runtime)
    return current, runtime


def test_cached_app_is_revalidated_after_settings_change(app_target, monkeypatch):
    current, runtime = app_target
    monkeypatch.setattr(server, "HOST", "192.0.2.20")
    assert runtime.app() is runtime._app
    current["pad"]["host"] = "192.0.2.21"
    with pytest.raises(capture.CaptureError, match="192.0.2.21"):
        runtime.app()


@pytest.mark.parametrize("operation", ["list_apps", "install", "push", "pull"])
async def test_file_tools_use_the_live_app_host(app_target, monkeypatch, tmp_path, operation):
    current, _ = app_target
    current["pad"]["host"] = "192.0.2.21"
    called = []

    async def claim():
        pass

    def action(host, *args, **kwargs):
        called.append(host)
        return "done"

    monkeypatch.setattr(server, "_check_claim", claim)
    path = tmp_path / "payload.elf"
    path.write_bytes(b"test payload")
    if operation == "list_apps":
        class Console:
            def __init__(self, host):
                called.append(host)

            def listdir(self, path):
                assert path == "/user/app"
                return [{"name": "PPSA12345"}]

        monkeypatch.setattr(probe_runner, "Console", Console)
        assert await server.list_apps() == ["PPSA12345"]
    elif operation == "install":
        monkeypatch.setattr(installer, "install", action)
        assert await server.install(str(path)) == "done"
    elif operation == "push":
        monkeypatch.setattr(transfer, "push", action)
        assert await server.push(str(path), "/data/payload.elf") == "done"
    else:
        monkeypatch.setattr(transfer, "pull", action)
        assert await server.pull("/data/payload.elf", str(path)) == "done"
    assert called == ["192.0.2.21"]


@pytest.mark.parametrize("operation", ["list_apps", "install", "push", "pull"])
async def test_file_tools_refuse_a_pinned_host_mismatch(app_target, monkeypatch, tmp_path, operation):
    current, _ = app_target
    monkeypatch.setattr(server, "HOST", "192.0.2.20")
    current["pad"]["host"] = "192.0.2.21"

    async def claim():
        pass

    def unexpected(*args, **kwargs):
        pytest.fail("a mismatched target must not receive a direct console request")

    monkeypatch.setattr(server, "_check_claim", claim)
    monkeypatch.setattr(probe_runner, "Console", unexpected)
    monkeypatch.setattr(installer, "install", unexpected)
    monkeypatch.setattr(transfer, "push", unexpected)
    monkeypatch.setattr(transfer, "pull", unexpected)
    if operation == "list_apps":
        result = await server.list_apps()
    elif operation == "install":
        result = await server.install(str(tmp_path / "payload.elf"))
    elif operation == "push":
        result = await server.push(str(tmp_path / "payload.elf"), "/data/payload.elf")
    else:
        result = await server.pull("/data/payload.elf", str(tmp_path / "payload.elf"))
    assert result.startswith("error:")
    assert "192.0.2.20" in result and "192.0.2.21" in result
