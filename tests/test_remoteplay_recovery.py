"""Reproduce snapshot and host-change recovery races with deterministic dependencies.

FrameSink is compiled from production. Hub/UI recovery and playback methods are
included verbatim with recorder/controller stubs, avoiding an AppKit window or a
console. The snapshot lock seam pauses a writer before it acquires its disk lock.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def swift_block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


@pytest.fixture(scope="module")
def recovery_binary(tmp_path_factory):
    directory = tmp_path_factory.mktemp("remoteplay-recovery")
    frames = (ROOT / "app/Frames.swift").read_text()
    assert "private let writeLock = NSLock()" in frames
    frames = frames.replace("private let writeLock = NSLock()", "private let writeLock = SnapshotTestLock()")
    (directory / "Frames.swift").write_text(frames)
    ui = (ROOT / "app/UI.swift").read_text()
    hub = (ROOT / "app/Hub.swift").read_text()
    methods = "\n".join(swift_block(ui, marker) for marker in (
        "func remotePlayStreamLost(", "private func stopVideo(", "private func videoSaved("))
    playback = swift_block(ui[ui.index("@objc func togglePlayback()"):], "Thread.detachNewThread")
    host_change = swift_block(hub, "func setHost(")
    source = r'''
import AVFoundation
import Foundation
func uptimeSeconds() -> Double { ProcessInfo.processInfo.systemUptime }
struct BadInput: Error { let message: String; init(_ message: String) { self.message=message } }
final class VideoRecorder {
    let url = URL(fileURLWithPath: "/tmp/recovery-test.mp4")
    var done: ((String?) -> Void)?
    func append(_ buffer: CVPixelBuffer, at time: CMTime) {}
    func append(audio: CMSampleBuffer) {}
    func finish(_ done: @escaping (String?) -> Void) { self.done=done }
}
final class SnapshotTestLock {
    static let control=NSLock(), parked=DispatchSemaphore(value: 0), resume=DispatchSemaphore(value: 0)
    static var armed=false
    private let underlying=NSLock()
    static func arm() { control.lock(); armed=true; control.unlock() }
    func lock() {
        Self.control.lock(); let park=Self.armed; Self.armed=false; Self.control.unlock()
        if park { Self.parked.signal(); precondition(Self.resume.wait(timeout: .now()+3) == .success) }
        underlying.lock()
    }
    func unlock() { underlying.unlock() }
}
struct PadState { var isNeutral=true }
final class TestController {
    var host="127.0.0.1"
    var presses=0
    var blocked=false
    let lock=NSLock()
    func setHost(_ host: String) { self.host=host }
    func setInputBlock(_ reason: String?) { blocked=reason != nil }
    func releaseAll() {}
    func release(client: String) {}
    func set(client: String, _ state: PadState) throws { lock.lock(); defer { lock.unlock() }; if !state.isNeutral { presses += 1 } }
    func current() -> (agents: [String: Bool], unused: Bool) { ([:], false) }
}
final class TestSource { func stop() {} }
let savedHostKey="test.remoteplay.host", missingHost="missing host"
final class TestHub {
    let controller=TestController()
    var host: String { controller.host }
    var captureVideo="remoteplay", captureIssue: String?, notice: String?
    func pbsHostChanged(_ host: String) {}
    var source: TestSource?=TestSource()
    let sink=FrameSink(path: "/tmp/unused-recovery.jpg", fps: 0)
    weak var ui: TestUI?
    var remotePlayHostChange: UInt64=0
    func statusChanged() {}
    HOST_CHANGE
}
final class TestUI {
    let hub: TestHub
    var videoRecorder: VideoRecorder?
    var videoSaving=false
    var afterVideoSaved: [() -> Void]=[]
    var restarts=0
    var playing: String?
    let playbackLock=NSLock()
    var playbackCancelled=false
    var stopPlayback: Bool {
        get { playbackLock.lock(); defer { playbackLock.unlock() }; return playbackCancelled }
        set { playbackLock.lock(); playbackCancelled=newValue; playbackLock.unlock() }
    }
    init(_ hub: TestHub) { self.hub=hub; hub.ui=self }
    func refresh() {}
    func finishSaving() { videoSaved("finished saving") }
    func restartCapture(video: String, audio: String?) throws {
        guard videoRecorder == nil, !videoSaving else { throw BadInput("still saving") }
        restarts += 1
    }
    METHODS
    func beginPlayback(_ states: [(PadState, Double)]) {
        let name="test"
        playing=name
        stopPlayback=false
        PLAYBACK
    }
}
func drain(until condition: () -> Bool, timeout: Double=2) {
    let end=uptimeSeconds()+timeout
    while !condition() && uptimeSeconds()<end { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    precondition(condition(), "timed out waiting for recovery")
}
@main struct RecoveryTests {
    static func main() {
        switch CommandLine.arguments[1] {
        case "snapshot":
            let path=CommandLine.arguments[2]+"/latest.jpg"
            let sink=FrameSink(path: path, fps: 0), buffer=makeBuffer()
            sink.push(buffer); precondition(sink.writeNow())
            let done=DispatchSemaphore(value: 0)
            let result=NSLock(); var wrote=true
            SnapshotTestLock.arm()
            DispatchQueue.global().async { let value=sink.writeNow(); result.lock(); wrote=value; result.unlock(); done.signal() }
            precondition(SnapshotTestLock.parked.wait(timeout: .now()+3) == .success)
            sink.clear()
            precondition(!FileManager.default.fileExists(atPath: path))
            SnapshotTestLock.resume.signal()
            precondition(done.wait(timeout: .now()+3) == .success)
            result.lock(); let staleWrite=wrote; result.unlock()
            precondition(!staleWrite, "pre-disconnect snapshot was accepted into a new timeline")
            precondition(!FileManager.default.fileExists(atPath: path), "delayed snapshot recreated stale latest.jpg")
            sink.push(buffer); precondition(sink.writeNow(), "new timeline cannot write")
            sink.invalidate()
            let replacement=FrameSink(path: path, fps: 0)
            replacement.push(buffer); precondition(replacement.writeNow())
            sink.clear()
            precondition(FileManager.default.fileExists(atPath: path), "old source removed replacement frame")
        case "host":
            let hub=TestHub(), ui: TestUI
            ui=TestUI(hub)
            let recorder=VideoRecorder(); ui.videoRecorder=recorder
            hub.setHost("127.0.0.2")
            precondition(ui.videoSaving && ui.restarts==0, "restart must await recording finalization")
            precondition(ui.stopPlayback, "host change did not cancel playback")
            hub.setHost("127.0.0.3") // Only the latest requested host should restart.
            precondition(ui.restarts==0)
            recorder.done?(nil)
            precondition(!ui.videoSaving && ui.restarts==1, "host change never retried capture after recording saved")
            precondition(hub.host=="127.0.0.3")
            ui.videoSaving=true // Existing Stop/save operation also defers the host change.
            hub.setHost("127.0.0.4")
            precondition(ui.restarts==1)
            ui.finishSaving()
            precondition(ui.restarts==2)
        case "playback":
            let hub=TestHub(), ui: TestUI
            ui=TestUI(hub)
            ui.beginPlayback([(PadState(),0.15),(PadState(isNeutral:false),0.1)])
            Thread.sleep(forTimeInterval: 0.03)
            ui.remotePlayStreamLost()
            // Reconnection removes the input gate before the old neutral interval ends.
            hub.controller.blocked=false
            drain(until: { ui.playing == nil })
            precondition(hub.controller.presses==0, "queued playback resumed after Remote Play loss")
        default: fatalError("unknown test")
        }
        print("recovery check passed")
    }
}
'''.replace("HOST_CHANGE", host_change).replace("METHODS", methods).replace("PLAYBACK", playback)
    (directory / "Harness.swift").write_text(source)
    binary = directory / "recovery-tests"
    compiled = subprocess.run(["swiftc", str(directory / "Frames.swift"), str(directory / "Harness.swift"), "-framework", "AVFoundation", "-framework", "CoreImage", "-o", str(binary)], capture_output=True, text=True, check=False)
    assert compiled.returncode == 0, compiled.stderr
    return binary


@pytest.mark.parametrize("case", ["snapshot", "host", "playback"])
def test_remoteplay_recovery(recovery_binary, tmp_path, case):
    result = subprocess.run([str(recovery_binary), case, str(tmp_path)], capture_output=True, text=True, timeout=15, check=False)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("scenario", ["timeline", "admission", "admission-failure", "admission-stop", "input", "crashed"])
def test_source_reconnect_waits_for_timeline_finalization(tmp_path, scenario):
    """Compile the complete production source with a controlled session/media backend."""
    harness = tmp_path / "SourceHarness.swift"
    harness.write_text(r'''
import AVFoundation
import Foundation
protocol RemotePlayAdmissionServicing: AnyObject {
    func apply(host: String, completion: @escaping (Result<Void, Error>) -> Void)
    func cancel()
}
final class RemotePlayAdmission: RemotePlayAdmissionServicing {
    static let sessionRequestUnknownReason = 2
    var calls = 0, cancellations = 0
    var completion: ((Result<Void, Error>) -> Void)?
    func apply(host: String, completion: @escaping (Result<Void, Error>) -> Void) { calls += 1; self.completion = completion }
    func cancel() { cancellations += 1 }
}
let RP_ERROR_IDENTITY = -2, RP_ERROR_INVALID = -1
func uptimeSeconds() -> Double { ProcessInfo.processInfo.systemUptime }
protocol FrameSource: AnyObject { var name: String { get }; func start(); func stop(); func setMuted(_ muted: Bool) }
struct RemotePlayCredentials { let consoleMAC=Data(repeating:1,count:6), registrationKey=Data(repeating:2,count:16), sessionKey=Data(repeating:3,count:16) }
final class FrameSink { func push(_ buffer: CVPixelBuffer, at time: CMTime) {}; func push(audio: CMSampleBuffer) {}; func clear() {} }
final class RemotePlayDecoder {
    static var output: ((CVPixelBuffer, CMTime) -> Void)?
    init(_ output: @escaping (CVPixelBuffer, CMTime) -> Void) { Self.output = output }
    static func frame() {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, nil, &buffer)
        output?(buffer!, .zero)
    }
    func submit(_ data: Data, at time: CMTime) -> Bool { true }
    func reset() {}
}
final class RemotePlayAudio {
    init(_ output: @escaping (CMSampleBuffer) -> Void) {}
    func submit(_ data: Data, samplesPerChannel: Int, channels: Int, rate: Int, at time: CMTime) {}
    func reset() {}; func setMuted(_ muted: Bool) {}
}
struct RemotePlayError: Error { let code: Int; var localizedDescription: String { "test error" } }
final class RemotePlaySession {
    struct Configuration { let host: String; let consoleMAC: Data; let registrationKey: Data; let rpKey: Data; var enableKeyboard = true }
    enum KeyboardEvent { case opened, confirmed, differs, closed }
    enum Event { case connected, disconnected(reason: Int), loginPINNeeded, failed(RemotePlayError), keyboard(KeyboardEvent) }
    static let lock=NSLock()
    static var instances: [RemotePlaySession]=[]
    static var holdStops=false
    static var pendingStops: [() -> Void]=[]
    static func finishStops() { lock.lock(); let pending=pendingStops; pendingStops=[]; lock.unlock(); pending.forEach { $0() } }
    static var started: Int { lock.lock(); defer { lock.unlock() }; return instances.count }
    static func instance(_ n: Int) -> RemotePlaySession { lock.lock(); defer { lock.unlock() }; return instances[n] }
    let onEvent: (Event) -> Void
    let configuration: Configuration
    var buttons: [UInt32]=[], texts: [String]=[], closes: [Bool]=[]
    var stopped=false
    init(configuration: Configuration, onVideo: @escaping (Data,Int32)->Bool, onAudio: @escaping (Data,Int,Int,Int)->Void, onEvent: @escaping (Event)->Void) { self.onEvent=onEvent; self.configuration=configuration }
    func setButtons(_ value: UInt32) -> Int32 { Self.lock.lock(); defer { Self.lock.unlock() }; if stopped { return -1 }; buttons.append(value); return 0 }
    func keyboardSetText(_ text: String) -> Int32 { Self.lock.lock(); defer { Self.lock.unlock() }; texts.append(text); return 0 }
    func keyboardClose(accept: Bool) -> Int32 { Self.lock.lock(); defer { Self.lock.unlock() }; closes.append(accept); return 0 }
    func start() { Self.lock.lock(); Self.instances.append(self); Self.lock.unlock() }
    func stop(completion: (() -> Void)? = nil) {
        Self.lock.lock()
        stopped=true
        if Self.holdStops, let completion { Self.pendingStops.append(completion); Self.lock.unlock() }
        else { Self.lock.unlock(); completion?() }
    }
}
func runFor(_ seconds: Double) {
    let end=uptimeSeconds()+seconds
    while uptimeSeconds()<end { _ = RunLoop.main.run(mode:.default,before:Date(timeIntervalSinceNow:0.01)) }
}
func waitFor(_ condition: ()->Bool) {
    let end=uptimeSeconds()+4
    while !condition() && uptimeSeconds()<end { runFor(0.01) }
    precondition(condition(),"source condition timed out")
}
@main struct SourceTests {
    static func main() {
        let admission = RemotePlayAdmission()
        let source=RemotePlaySource(host:"127.0.0.1",credentials:RemotePlayCredentials(),sink:FrameSink(), admission: admission)
        let scenario = CommandLine.arguments[1]
        if scenario == "crashed" {
            source.start(); waitFor { RemotePlaySession.started == 1 }
            RemotePlaySession.instance(0).onEvent(.disconnected(reason: 5))
            waitFor { source.json["state"] as? String == "unavailable" }
            precondition((source.json["error"] as? String ?? "").contains("restart the PS5"))
            runFor(2.5)
            precondition(RemotePlaySession.started == 1 && admission.calls == 0, "retried a crashed Remote Play service")
            source.stop(); print("crashed service stops retrying"); return
        }
        if scenario == "input" {
            func refuses(_ text: String, _ body: () throws -> Void) {
                do { try body(); preconditionFailure("accepted input: \(text)") }
                catch { precondition("\(error)".contains(text), "unexpected error: \(error)") }
            }
            refuses("not running") { try source.setButtons(1 << 15) }
            source.start(); waitFor { RemotePlaySession.started == 1 }
            let first = RemotePlaySession.instance(0)
            precondition(first.configuration.enableKeyboard)
            first.onEvent(.connected); waitFor { source.json["state"] as? String == "waiting_for_video" }
            // Transport alone is not live video: nothing may be sent blind.
            refuses("not delivering video") { try source.setButtons(1 << 15) }
            RemotePlayDecoder.frame(); waitFor { source.status.phase == .streaming }
            try! source.setButtons(1 << 15); source.releaseButtons()
            precondition(first.buttons == [1 << 15, 0])
            refuses("No PS5 text field is open") { _ = try source.setKeyboardText("hi", timeout: 1) }
            first.onEvent(.keyboard(.opened)); waitFor { source.isKeyboardOpen }
            precondition((source.json["keyboard"] as? [String: Bool])?["open"] == true)
            var result: RemotePlayKeyboardResult?
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { result = try? source.setKeyboardText("héllo", timeout: 3); answered.signal() }
            waitFor { RemotePlaySession.lock.lock(); defer { RemotePlaySession.lock.unlock() }; return first.texts == ["héllo"] }
            first.onEvent(.keyboard(.opened))  // a re-open is not an answer
            runFor(0.1); precondition(result == nil)
            first.onEvent(.keyboard(.confirmed))
            precondition(answered.wait(timeout: .now() + 3) == .success && result == .confirmed)
            precondition(try! source.setKeyboardText("x", timeout: 0.2) == .timeout)
            // Loss while waiting ends the request; the new timeline starts with the keyboard closed.
            DispatchQueue.global().async { result = try? source.setKeyboardText("lost", timeout: 3); answered.signal() }
            waitFor { RemotePlaySession.lock.lock(); defer { RemotePlaySession.lock.unlock() }; return first.texts.count == 3 }
            first.onEvent(.disconnected(reason: 9))
            precondition(answered.wait(timeout: .now() + 3) == .success && result == .closed)
            precondition(!source.isKeyboardOpen)
            refuses("not delivering video") { _ = try source.setKeyboardText("x", timeout: 1) }
            waitFor { RemotePlaySession.started == 2 }
            let second = RemotePlaySession.instance(1)
            second.onEvent(.keyboard(.opened)); RemotePlayDecoder.frame(); waitFor { source.status.phase == .streaming && source.isKeyboardOpen }
            try! source.closeKeyboard(accept: true)
            precondition(second.closes == [true] && !source.isKeyboardOpen)
            refuses("No PS5 text field is open") { try source.closeKeyboard(accept: false) }
            source.stop(); waitFor { source.json["state"] as? String == "stopped" }
            refuses("not running") { try source.setButtons(1 << 15) }
            let off = RemotePlaySource(host:"127.0.0.1",credentials:RemotePlayCredentials(),sink:FrameSink(), admission: admission, enableKeyboard: false)
            off.start(); waitFor { RemotePlaySession.started == 3 }
            precondition(!RemotePlaySession.instance(2).configuration.enableKeyboard)
            refuses("turned off") { _ = try off.setKeyboardText("x", timeout: 1) }
            off.stop(); print("input gating passed"); return
        }
        if scenario != "timeline" {
            source.start(); waitFor { RemotePlaySession.started == 1 }
            RemotePlaySession.instance(0).onEvent(.disconnected(reason:2))
            waitFor { admission.calls == 1 }
            runFor(2.2)
            precondition(RemotePlaySession.started == 1, "reconnected before admission completed")
            if scenario == "admission-stop" {
                source.stop(); waitFor { source.json["state"] as? String == "stopped" }
                admission.completion?(.success(())); runFor(2.2)
                precondition(RemotePlaySession.started == 1 && source.json["state"] as? String == "stopped")
                precondition(admission.cancellations > 0)
            } else if scenario == "admission-failure" {
                admission.completion?(.failure(NSError(domain:"fixture",code:1)))
                waitFor { source.json["state"] as? String == "unavailable" }
                runFor(2.2); precondition(RemotePlaySession.started == 1)
            } else {
                admission.completion?(.success(())); waitFor { RemotePlaySession.started == 2 }
                RemotePlaySession.instance(1).onEvent(.disconnected(reason:2))
                waitFor { RemotePlaySession.started == 3 }
                precondition(admission.calls == 1, "repeated admission within one start")
            }
            source.stop(); print("admission barrier passed"); return
        }
        var finalize: (() -> Void)?
        source.onStreamLost = { completion in finalize=completion }
        source.start()
        waitFor { RemotePlaySession.started==1 }
        RemotePlaySession.instance(0).onEvent(.disconnected(reason:9))
        waitFor { finalize != nil }
        runFor(2.2)
        precondition(RemotePlaySession.started==1,"session reconnected while old recording was still saving")
        finalize?(); finalize=nil
        waitFor { RemotePlaySession.started==2 }
        RemotePlaySession.lock.lock(); RemotePlaySession.holdStops=true; RemotePlaySession.lock.unlock()
        RemotePlaySession.instance(1).onEvent(.disconnected(reason:9))
        waitFor { finalize != nil }
        finalize?()
        runFor(2.2)
        precondition(RemotePlaySession.started==2,"new session started before native stop/join completed")
        source.stop()
        waitFor { source.json["state"] as? String == "stopped" }
        finalize?(); RemotePlaySession.finishStops()
        runFor(2.2)
        precondition(RemotePlaySession.started==2,"stopped source reconnected from a late finalization callback")
        print("source finalization barrier passed")
    }
}
''')
    binary = tmp_path / "source-recovery"
    compiled = subprocess.run(["swiftc", str(ROOT / "app/RemotePlayStatus.swift"),
                               str(ROOT / "app/RemotePlaySource.swift"), str(harness),
                               "-framework", "AVFoundation", "-o", str(binary)],
                              capture_output=True, text=True, check=False)
    assert compiled.returncode == 0, compiled.stderr
    result = subprocess.run([str(binary), scenario], capture_output=True, text=True, timeout=15, check=False)
    assert result.returncode == 0, result.stderr
