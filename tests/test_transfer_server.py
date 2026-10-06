"""Launch must not bypass an incomplete native-title upload in this MCP session."""
import asyncio

from ps5mcp import server, transfer


async def test_launch_is_blocked_until_title_upload_checks_finish(tmp_path, monkeypatch):
    title = tmp_path / "title"
    (title / "sce_sys").mkdir(parents=True)
    (title / "eboot.bin").write_bytes(b"executable")
    (title / "sce_sys/param.json").write_text('{"titleId":"PPSA99764"}')
    entered = asyncio.Event()
    finish = asyncio.Event()
    loop = asyncio.get_running_loop()
    launches = []

    async def claim():
        pass

    async def command(op, arg):
        launches.append((op, arg))
        return 0

    def uploading(*args, **kwargs):
        loop.call_soon_threadsafe(entered.set)
        asyncio.run_coroutine_threadsafe(finish.wait(), loop).result()
        raise RuntimeError("registration unverified")

    monkeypatch.setattr(server, "runtime", server.Runtime())
    monkeypatch.setattr(server, "_check_claim", claim)
    monkeypatch.setattr(server, "_command", command)
    monkeypatch.setattr(server.runtime, "target_host", lambda: "127.0.0.1")
    monkeypatch.setattr(transfer, "push", uploading)
    upload = asyncio.create_task(server.mcp.call_tool("push", {
        "local_path": str(title), "remote_path": "/title"}))
    await entered.wait()
    try:
        result = await server.mcp.call_tool("launch", {"title_id": "PPSA99764", "snapshot_after_ms": None})
        assert "upload" in result.content[0].text
        assert launches == []
    finally:
        finish.set()
        await upload
    result = await server.mcp.call_tool("launch", {"title_id": "PPSA99764", "snapshot_after_ms": None})
    assert "retry push" in result.content[0].text
    assert launches == []

    monkeypatch.setattr(transfer, "push", lambda *args, **kwargs: "permissions and registration verified")
    await server.mcp.call_tool("push", {"local_path": str(title), "remote_path": "/title"})
    await server.mcp.call_tool("launch", {"title_id": "PPSA99764", "snapshot_after_ms": None})
    assert launches == [("launch", "PPSA99764")]
