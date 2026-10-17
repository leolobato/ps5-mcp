"""Admission recovery retains the authority of the source start, not a later claimant."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def test_recovery_cannot_follow_a_new_console_owner(tmp_path):
    harness = tmp_path / 'LeaseHarness.swift'
    harness.write_text('''
import Foundation
func say(_ value: String) {}
func uptimeSeconds() -> Double { ProcessInfo.processInfo.systemUptime }
struct ApiError: Error { let code: String; let message: String }
@main struct Test {
 static func main() throws {
  let lease = Lease()
  let free = lease.recoveryAuthorization()
  try free()
  _ = lease.claim(conn: 1, client: "first", reason: "test", idle: 600)
  do { try free(); fatalError("unclaimed recovery stole a later lease") } catch {}
  let owned = lease.recoveryAuthorization()
  try owned()
  lease.unclaim(conn: 1); try owned()
  _ = lease.claim(conn: 2, client: "first", reason: "test", idle: 600)
  do { try owned(); fatalError("recovery followed a new owner with the same name") } catch {}
 }
}
''')
    binary = tmp_path / 'lease-test'
    result = subprocess.run(['swiftc', str(ROOT / 'app/Lease.swift'), str(harness), '-o', str(binary)], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr
    subprocess.run([str(binary)], check=True)
