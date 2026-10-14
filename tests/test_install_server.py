"""Expected installation failures preserve actionable details as MCP tool errors."""

import http.client

import pytest
from mcp.server.mcpserver.exceptions import ToolError, UnexpectedToolError

from ps5mcp import installer, server


@pytest.mark.parametrize("error", [
    RuntimeError("upload task disappeared; outcome unknown, check the console before retrying"),
    TimeoutError("pkg_install task was not observed; outcome unknown"),
    OSError("console disconnected"),
    http.client.BadStatusLine("invalid response"),
])
async def test_install_failure_is_an_expected_tool_error(monkeypatch, error):
    async def claim():
        pass

    def failing(*args, **kwargs):
        raise error

    monkeypatch.setattr(server, "_check_claim", claim)
    monkeypatch.setattr(server.runtime, "target_host", lambda: "192.0.2.20")
    monkeypatch.setattr(installer, "install", failing)
    with pytest.raises(ToolError, match="install failed") as caught:
        await server.mcp.call_tool("install", {"path": "game.pkg"})
    assert not isinstance(caught.value, UnexpectedToolError)
    assert str(error) in str(caught.value)
