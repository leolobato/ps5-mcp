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
        def __init__(self, host, port=None):
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


def _build(root, elf=b"\x7fELF padd", version="1.4"):
    import hashlib
    import json
    (root / "build").mkdir(parents=True, exist_ok=True)
    (root / "build/padd.elf").write_bytes(elf)
    report = {"artifacts": {"padd.elf": {"sha256": hashlib.sha256(elf).hexdigest(), "version": version}}}
    (root / "build/toolchain-report.json").write_text(json.dumps(report))


def test_bundled_build_reports_its_version_and_staleness(tmp_path, monkeypatch):
    from ps5mcp import padd_runner
    monkeypatch.setattr(padd_runner, "ROOT", tmp_path)
    assert padd_runner.bundled()["version"] is None
    _build(tmp_path)
    assert padd_runner.bundled()["version"] == "1.4" and not padd_runner.bundled()["stale"]
    (tmp_path / "build/padd.elf").write_bytes(b"rebuilt without verify")
    assert padd_runner.bundled()["stale"]


def test_update_stops_the_running_padd_before_starting_the_build(tmp_path, monkeypatch):
    from ps5mcp import padd_runner
    monkeypatch.setattr(padd_runner, "ROOT", tmp_path)
    _build(tmp_path)
    steps = []
    listening = iter([True, True, False])  # padd takes a moment to exit after SHUTDOWN
    monkeypatch.setattr(padd_runner, "preflight", lambda host: steps.append("preflight"))
    monkeypatch.setattr(padd_runner, "_port_open", lambda host: next(listening))
    monkeypatch.setattr(padd_runner, "stop", lambda host: steps.append("stop") or 1)  # "unverified" is fine
    monkeypatch.setattr(padd_runner, "start", lambda host, firmware: steps.append(("start", firmware)) or 0)
    monkeypatch.setattr(padd_runner.time, "sleep", lambda s: None)
    assert padd_runner.update("ps5", "13.60") == 0
    assert steps == ["preflight", "stop", ("start", "13.60")]


def test_update_leaves_padd_running_when_it_cannot_deploy(tmp_path, monkeypatch):
    import pytest

    from ps5mcp import padd_runner
    monkeypatch.setattr(padd_runner, "ROOT", tmp_path)
    _build(tmp_path)
    (tmp_path / "build/padd.elf").write_bytes(b"rebuilt without verify")
    monkeypatch.setattr(padd_runner, "stop", lambda host: pytest.fail("stopped padd with nothing to deploy"))
    with pytest.raises(SystemExit, match="stale"):
        padd_runner.update("ps5", "13.60")
    _build(tmp_path)
    monkeypatch.setattr(padd_runner, "preflight", lambda host: (_ for _ in ()).throw(SystemExit("no WFM")))
    with pytest.raises(SystemExit, match="no WFM"):
        padd_runner.update("ps5", "13.60")


def test_build_report_records_the_padd_version_from_its_source(tmp_path):
    import importlib.util

    from ps5mcp import padd_runner
    spec = importlib.util.spec_from_file_location("verify", padd_runner.ROOT / "scripts/verify.py")
    verify = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verify)
    source = tmp_path / "padd.c"
    source.write_text("/* 1.3: uninstall */\n#define PADD_VERSION 0x010a\n")
    assert verify.padd_version(source) == "1.10"


def test_stop_waits_out_a_busy_slot(monkeypatch):
    from ps5mcp import padd_runner
    from ps5mcp.client import PadBusy
    answers = iter([PadBusy("another client is connected")] * 2 + ["link"])

    def link(host, port):
        answer = next(answers)
        if isinstance(answer, Exception):
            raise answer
        return answer
    monkeypatch.setattr(padd_runner, "PadLink", link)
    monkeypatch.setattr(padd_runner.time, "sleep", lambda s: None)
    assert padd_runner._connect("ps5") == "link"
