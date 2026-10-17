"""Run the production Forget action and capture guard with isolated storage/media."""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def swift_method(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


@pytest.fixture(scope="module")
def forget_binary(tmp_path_factory):
    directory = tmp_path_factory.mktemp("remoteplay-forget")
    settings = (ROOT / "app/Settings.swift").read_text()
    ui = (ROOT / "app/UI.swift").read_text()
    forget = swift_method(settings, "private func forgetPairing()")
    restart = swift_method(ui, "func restartCapture(")
    readiness = swift_method(ui, "func validateCaptureChange(") if "func validateCaptureChange(" in ui else ""
    harness = r'''
import Foundation
struct BadInput: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description=description }
}
struct RemotePlaySetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message=message }
    var errorDescription: String? { message }
}
final class MemorySecrets: RemotePlaySecretStorage {
    var items: [String: Data]=[:]
    func read(_ key: String) throws -> Data? { items[key] }
    func write(_ data: Data, key: String) throws { items[key]=data }
    func delete(_ key: String) throws { items.removeValue(forKey:key) }
}
final class TestLease { var json: [String: Any]=["owner":NSNull()] }
class TestLayer { func removeFromSuperlayer() {} }
final class AVCaptureVideoPreviewLayer: TestLayer { var session: Int? }
final class TestSource {
    var stopped=0, started=0
    func stop() { stopped += 1 }
    func start() { started += 1 }
    func setMuted(_ value: Bool) {}
}
final class TestHub {
    var host="192.0.2.15", captureVideo="remoteplay"
    let remotePlayCredentials: RemotePlayCredentialStore
    let lease=TestLease(), source=TestSource()
    var ui: TestUI?
    var visible=false
    init(_ store: RemotePlayCredentialStore) { remotePlayCredentials=store }
    func configureCapture(video: String, audio: String?) {}
    func statusChanged() {}
}
final class TestUI {
    let hub: TestHub
    var videoRecorder: Int?, videoSaving=false, audioMuted=false
    let previewLayer=TestLayer()
    init(_ hub: TestHub) { self.hub=hub; hub.ui=self }
    func attachCapturePreview() {}
    READINESS
    RESTART
}
final class TestText { var stringValue="" }
final class NSAlert {
    enum Response { case alertFirstButtonReturn }
    static var beforeResponse: (() -> Void)?
    var messageText="", informativeText=""
    func addButton(withTitle title: String) {}
    func beginSheetModal(for window: Int, completionHandler: @escaping (Response)->Void) {
        Self.beforeResponse?(); completionHandler(.alertFirstButtonReturn)
    }
}
final class TestSettings {
    let hub: TestHub
    let window=0, remotePlayNote=TestText()
    var refreshed=0
    init(_ hub: TestHub) { self.hub=hub }
    func refreshCaptureStatus() { refreshed += 1 }
    func performForget() { forgetPairing() }
    FORGET
}
@main struct ForgetTests {
    static func main() throws {
        let suite="ps5mcp.forget-tests.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store=RemotePlayCredentialStore(secrets:MemorySecrets(),defaults:defaults)
        let record=try RemotePlayCredentials(consoleID:"aabbccddeeff",nickname:"PS5",
            accountID:Data(repeating:1,count:8),registrationKey:Data(repeating:2,count:16),
            sessionKey:Data(repeating:3,count:16),host:"192.0.2.15")
        try store.save(record)
        let hub=TestHub(store), ui=TestUI(hub), settings=TestSettings(hub)
        switch CommandLine.arguments[1] {
        case "recording": ui.videoRecorder=1
        case "saving": ui.videoSaving=true
        case "host": NSAlert.beforeResponse = { hub.host="192.0.2.16" }
        case "source": NSAlert.beforeResponse = { hub.captureVideo="capture-card" }
        case "leased": NSAlert.beforeResponse = { hub.lease.json=["owner":["client":"worker"]] }
        case "not-ready": hub.ui=nil
        case "success": break
        case "capture-card": hub.captureVideo="capture-card"; ui.videoRecorder=1
        default: fatalError("unknown test")
        }
        settings.performForget()
        let stored=try store.load(host:"192.0.2.15")
        switch CommandLine.arguments[1] {
        case "success":
            precondition(stored == nil && hub.source.stopped==1 && hub.source.started==1,
                "successful forget must stop the old Remote Play source")
        case "capture-card":
            precondition(stored == nil && hub.source.stopped==0 && ui.videoRecorder==1,
                "forgetting inactive pairing must leave capture-card recording running")
        default:
            precondition(stored == record,"rejected forget deleted credentials")
            precondition(hub.source.stopped==0 && hub.source.started==0,"rejected forget changed the stream")
            precondition(!settings.remotePlayNote.stringValue.isEmpty,"rejection needs a visible explanation")
            if ["recording","saving"].contains(CommandLine.arguments[1]) {
                precondition(settings.remotePlayNote.stringValue.contains("recording"),"recording rejection lost its useful explanation")
            }
        }
        print("forget check passed")
    }
}
'''.replace("FORGET", forget).replace("READINESS", readiness).replace("RESTART", restart)
    source = directory / "ForgetHarness.swift"
    source.write_text(harness)
    binary = directory / "forget-tests"
    compiled = subprocess.run([
        "swiftc", str(ROOT / "app/RemotePlayCredentials.swift"), str(source),
        "-framework", "Security", "-o", str(binary),
    ], capture_output=True, text=True, check=False)
    assert compiled.returncode == 0, compiled.stderr
    return binary


@pytest.mark.parametrize("case", [
    "recording", "saving", "host", "source", "leased", "not-ready", "success", "capture-card",
])
def test_remoteplay_forget_preserves_credentials_until_capture_ready(forget_binary, case):
    result = subprocess.run([str(forget_binary), case], capture_output=True, text=True, timeout=10, check=False)
    assert result.returncode == 0, result.stderr
