def test_padd_log_tolerates_system_library_output():
    from ps5mcp.padd_runner import classify as classify_padd
    raw = (b'{"event":"pad_added","ok":true}\n[SceLncUtil] launchApp: LNC_ISOK::0x80940033\n'
           b'{"event":"pad_removed","status":0}\n{"event":"exit_requested","code":0}\n')
    status, records = classify_padd(raw)
    assert status == "passed" and records[1] == {"foreign": "[SceLncUtil] launchApp: LNC_ISOK::0x80940033"}
    assert classify_padd(b'{"event":"pad_added","ok":true}\n')[0] == "running"
    assert classify_padd(b'{"event":"pad_added","ok":true}\n{"event":"exit_req')[0] == "incomplete"


def test_run_pointer_survives_a_moved_checkout(tmp_path, monkeypatch):
    from ps5mcp import padd_runner
    monkeypatch.setenv("PS5MCP_STATE", str(tmp_path))
    run = padd_runner.ROOT / "results" / "20990101T000000.000000Z-padd"
    pointer = padd_runner.current_run_file()
    pointer.write_text("results/20990101T000000.000000Z-padd\n")
    assert padd_runner.current_run() == run
    monkeypatch.setattr(padd_runner, "ROOT", tmp_path)
    (tmp_path / "results" / run.name).mkdir(parents=True)
    pointer.write_text(f"/old/checkout/results/{run.name}\n")  # written by an older version, before the move
    assert padd_runner.current_run() == tmp_path / "results" / run.name


def test_stop_of_a_padd_without_a_recorded_run_checks_only_its_port(tmp_path, monkeypatch, capsys):
    import json
    from types import SimpleNamespace

    from ps5mcp import padd_runner
    monkeypatch.setenv("PS5MCP_STATE", str(tmp_path))
    monkeypatch.setattr(padd_runner, "ROOT", tmp_path)
    run = tmp_path / "results" / "old-padd"
    run.mkdir(parents=True)
    (run / "run.json").write_text(json.dumps({"hello": {"pad_handle": 1}, "status": "running"}))
    padd_runner.current_run_file().write_text("results/old-padd\n")
    shutdowns = []

    class Link:
        def __init__(self, host):
            self.hello = SimpleNamespace(pad_handle=2)  # padd launched from Payload Manager: a different pad

        def shutdown(self):
            shutdowns.append(True)

        def close(self):
            pass

    monkeypatch.setattr(padd_runner, "PadLink", Link)
    monkeypatch.setattr(padd_runner, "_port_open", lambda host: False)
    assert padd_runner.stop("ps5") == 0
    assert shutdowns and capsys.readouterr().out.startswith("stopped: ")
    assert json.loads((run / "run.json").read_text()) == {"hello": {"pad_handle": 1}, "status": "running"}
