import AVFoundation
import Foundation

func uptimeSeconds() -> Double { ProcessInfo.processInfo.systemUptime }
struct BadInput: Error { let message: String; init(_ message: String) { self.message = message } }

/// PBSSource's Settings actions against the fake service in tests/test_pbs_source.py.
@main
struct PBSSourceTests {
    static func spin(until condition: () -> Bool, _ message: String) {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            precondition(Date() < deadline, message)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    static func stop(_ source: PBSSource) -> Bool {
        var answer: Bool?
        source.stopPayload { answer = $0 }
        spin(until: { answer != nil }, "stopPayload never answered")
        return answer!
    }

    static func load(_ source: PBSSource) -> PBSSource.LoadResult {
        var answer: PBSSource.LoadResult?
        source.loadPayload { answer = $0 }
        spin(until: { answer != nil }, "loadPayload never answered")
        return answer!
    }

    static func main() {
        precondition(PBSSource.libraryPayload(["/p/zftpd/zftpd.elf", "/p/PBS/PBS-Payload-0.3.0-ps4.elf"]) == nil, "PS4 build chosen")
        precondition(PBSSource.libraryPayload(["/p/a/PBS-Payload-0.9.0-ps5.elf", "/p/b/PBS-Payload-0.10.0-ps5.elf"])
                     == "/p/b/PBS-Payload-0.10.0-ps5.elf", "newest version not chosen")
        let arguments = CommandLine.arguments
        let sink = FrameSink(path: arguments[3], fps: 5)
        let source = PBSSource(host: "127.0.0.1", port: Int(arguments[1])!, sink: sink, managerPort: Int(arguments[1])!)
        source.start()
        spin(until: { source.status.videoReady }, "no first frame")

        source.reconnect()
        spin(until: { source.status.reconnects == 1 }, "reconnect did not end the stream")
        spin(until: { source.status.videoReady }, "reconnect did not bring video back")

        precondition(load(source) == .started("PBS-Payload-0.1.0-ps5.elf"), "library copy was not started")
        precondition(stop(source), "a running PBS must answer stop")
        source.stop()

        let empty = PBSSource(host: "127.0.0.1", port: Int(arguments[1])!, sink: sink, managerPort: Int(arguments[4])!)
        precondition(load(empty) == .notInLibrary, "an empty library must say so")
        let noManager = PBSSource(host: "127.0.0.1", port: Int(arguments[2])!, sink: sink, managerPort: Int(arguments[2])!)
        precondition(load(noManager) == .unreachable, "a missing Payload Manager must say so")

        let missing = PBSSource(host: "127.0.0.1", port: Int(arguments[2])!, sink: sink)
        precondition(!stop(missing), "a missing PBS must report no answer")
        print("pbs source checks passed")
    }
}
