"""Setup completion requires both media types from the current session."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def test_setup_verification_observes_media_and_session_boundaries(tmp_path):
    harness = tmp_path / 'Verification.swift'
    harness.write_text('''
import Foundation
@main struct Test {
 static func main() {
  let target = RemotePlayPairingTarget(host: "192.0.2.1", captureGeneration: 4)
  precondition(target.matches(host: "192.0.2.1", captureGeneration: 4))
  precondition(!target.matches(host: "192.0.2.1", captureGeneration: 5))
  precondition(!target.matches(host: "192.0.2.2", captureGeneration: 4))
  var verification = RemotePlaySetupVerification()
  var status = RemotePlayStatus()
  status.phase = .applyingAdmission; status.generation = 1
  precondition(verification.observe(status, now: 0) == .pending)
  precondition(verification.observe(status, now: 40) == .pending)
  status.phase = .waitingForVideo
  precondition(verification.observe(status, now: 41) == .pending)
  status.phase = .streaming; status.videoReady = true
  precondition(verification.observe(status, now: 50) == .pending)
  precondition(verification.observe(status, now: 51) == .incomplete)
  verification = RemotePlaySetupVerification()
  status.generation = 2; status.audioReady = true
  precondition(verification.observe(status, now: 60) == .verified)
  status.generation = 3; status.audioReady = false
  precondition(verification.observe(status, now: 61) == .pending)
  verification = RemotePlaySetupVerification()
  status.phase = .waitingForVideo; status.videoReady = false
  precondition(verification.observe(status, now: 100) == .pending)
  status.generation += 1; status.phase = .reconnecting
  precondition(verification.observe(status, now: 103) == .pending)
  status.generation += 1; status.phase = .waitingForVideo
  precondition(verification.observe(status, now: 106) == .pending)
  status.generation += 1
  precondition(verification.observe(status, now: 110) == .incomplete)
  status.phase = .unavailable
  precondition(verification.observe(status, now: 62) == .incomplete)
  // A console that never connects (unreachable, or refusing again after admission) still ends verification.
  verification = RemotePlaySetupVerification()
  status.phase = .reconnecting; status.videoReady = false
  precondition(verification.observe(status, now: 200) == .pending)
  status.phase = .applyingAdmission
  precondition(verification.observe(status, now: 230) == .pending)
  status.phase = .reconnecting
  precondition(verification.observe(status, now: 259) == .pending)
  precondition(verification.observe(status, now: 260) == .incomplete)
 }
}
''')
    binary = tmp_path / 'verification'
    compiled = subprocess.run(['swiftc', str(ROOT / 'app/RemotePlayStatus.swift'), str(ROOT / 'app/RemotePlaySetupState.swift'), str(harness), '-o', str(binary)], capture_output=True, text=True, check=False)
    assert compiled.returncode == 0, compiled.stderr
    subprocess.run([str(binary)], check=True)
