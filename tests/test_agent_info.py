"""The window's claim details: the API client's process and the agent above its launchers."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_agent_description_names_the_client_and_its_agent(tmp_path):
    harness = tmp_path / "main.swift"
    harness.write_text('''
import Foundation
let me = ProcessDetails(pid: getpid())!
precondition(me.name == "agent-info-test" && me.arguments.last == "--session-id-probe")
precondition(me.cwd == FileManager.default.currentDirectoryPath)
precondition(ProcessDetails(pid: 0) == nil && ProcessDetails(pid: 99_999_999) == nil)
precondition(agentDescription(pid: nil) == "process: unknown")
let text = agentDescription(pid: getpid())
precondition(text.hasPrefix("client process: agent-info-test (pid \\(getpid()))"), text)
precondition(text.contains("\\nagent: "), text)  // pytest's Python is a launcher; the line names what started it
let long = ProcessDetails(pid: getpid())!.describe("x", limit: 5)
precondition(long.contains("…"), long)
print("ok")
''')
    binary = tmp_path / "agent-info-test"
    compiled = subprocess.run(["swiftc", str(ROOT / "app/AgentInfo.swift"), str(harness), "-o", str(binary)],
                              capture_output=True, text=True, check=False)
    assert compiled.returncode == 0, compiled.stderr
    result = subprocess.run([str(binary), "--session-id-probe"], cwd=tmp_path, capture_output=True, text=True,
                            check=False)
    assert result.returncode == 0 and result.stdout.strip() == "ok", result.stderr
