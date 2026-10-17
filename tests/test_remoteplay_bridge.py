"""Compile production bridge against real pinned headers, substituting only the network backend."""
import subprocess
from pathlib import Path


def test_native_bridge_lifecycle(tmp_path):
    root = Path(__file__).resolve().parents[1]
    binary = tmp_path / "bridge-tests"
    subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread", "-I", str(root / "app"), "-I", str(root / "third-party/chiaki-ng/lib/include"), str(root / "app/RemotePlayBridge.c"), str(root / "tests/native/RemotePlayBridgeTests.c"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)


def test_swift_wrapper_validation_and_callback_stop(tmp_path):
    """Link the actual dependency closure and exercise asynchronous wrapper shutdown."""
    import importlib.util
    import platform

    import pytest

    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("remoteplay_build", root / "scripts/build-remoteplay.py")
    module = importlib.util.module_from_spec(spec)
    import sys
    sys.path.insert(0, str(root / "scripts"))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    config = module.configuration(platform.machine())
    if not all(Path(lib).exists() for lib in config["libraries"]):
        pytest.skip("Run make remoteplay before real static-link Swift wrapper checks")
    import socket
    import threading
    console = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    console.bind(("127.0.0.1", 9302))
    console.settimeout(10)
    def answer_discovery():
        try:
            _, peer = console.recvfrom(2048)
            console.sendto(b"HTTP/1.1 200 Ok\nhost-type:PS5\nhost-id:010203040506\n\n", peer)
        finally:
            console.close()
    responder = threading.Thread(target=answer_discovery, daemon=True)
    responder.start()
    source = tmp_path / "main.swift"
    source.write_text('''import Foundation
let done = DispatchSemaphore(value: 0)
let session = RemotePlaySession(configuration: .init(host: "127.0.0.1", consoleMAC: Data(), registrationKey: Data(), rpKey: Data()), onVideo: { _,_ in fatalError("unexpected video") }, onAudio: { _,_,_,_ in fatalError("unexpected audio") }, onEvent: { event in
    guard case .failed(let error) = event, error.code == Int(RP_ERROR_INVALID) else { fatalError("expected validation error") }
    session.stop { done.signal() }
})
session.start()
precondition(done.wait(timeout: .now() + 3) == .success)
let registration = RemotePlayRegistration()
for pin in ["1234567", "123456789", "12a45678", "１２３４５６７８"] {
    registration.start(host: "127.0.0.1", accountID: Data(repeating: 0, count: 8), pin: pin) { result in
        guard case .failure(let error) = result, error.code == Int(RP_ERROR_INVALID) else { fatalError("expected invalid PIN") }
        registration.cancel()
        done.signal()
    }
    precondition(done.wait(timeout: .now() + 3) == .success)
}
// Immediate cancellation invalidates pending work and callbacks.
registration.start(host: "127.0.0.1", accountID: Data(repeating: 0, count: 8), pin: "00000000") { _ in fatalError("stale completion") }
registration.cancel()
session.start()
session.stop { done.signal() }
precondition(done.wait(timeout: .now() + 3) == .success)
let live = RemotePlaySession(configuration: .init(host: "127.0.0.1", consoleMAC: Data([1,2,3,4,5,6]), registrationKey: Data(repeating: 0, count: 16), rpKey: Data(repeating: 0, count: 16)), onVideo: { _,_ in true }, onAudio: { _,_,_,_ in }, onEvent: { _ in })
live.start()
Thread.sleep(forTimeInterval: 0.15)
live.stop { done.signal() }
precondition(done.wait(timeout: .now() + 3) == .success)
print("Swift wrapper validation and asynchronous teardown passed")
''')
    bridge_object = tmp_path / "bridge.o"
    subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=14.0", "-I", str(root / "app"), "-I", config["include_dirs"][0], "-c", str(root / "app/RemotePlayBridge.c"), "-o", str(bridge_object)], check=True)
    binary = tmp_path / "swift-bridge-tests"
    frameworks = [arg for name in config["frameworks"] for arg in ("-framework", name)]
    subprocess.run(["swiftc", "-warnings-as-errors", "-import-objc-header", str(root / "app/RemotePlayBridge.h"), str(root / "app/RemotePlaySession.swift"), str(source), str(bridge_object), *config["libraries"], *frameworks, "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
    responder.join(timeout=1)
    assert not responder.is_alive(), "real native lifecycle did not discover the simulated console"
    dependencies = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    assert "/opt/homebrew/" not in dependencies and "/usr/local/" not in dependencies
