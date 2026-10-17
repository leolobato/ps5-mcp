import Foundation

/// Pairing is independent of live media verification. Reconnects cannot extend its deadline: media must arrive
/// within 10 s of connecting, and the whole attempt (admission, console teardown, retries) ends after 60 s.
struct RemotePlaySetupVerification {
    enum Outcome { case pending, verified, incomplete }
    static let overall: TimeInterval = 60
    private var startedAt: TimeInterval?
    private var connectedAt: TimeInterval?
    mutating func observe(_ status: RemotePlayStatus, now: TimeInterval) -> Outcome {
        if startedAt == nil { startedAt = now }
        if status.phase == .unavailable || status.phase == .stopped { return .incomplete }
        if status.phase == .streaming && status.videoReady && status.audioReady { return .verified }
        if status.phase == .waitingForVideo || status.phase == .streaming {
            if connectedAt == nil { connectedAt = now }
        }
        if let connectedAt, now - connectedAt >= 10 { return .incomplete }
        if let startedAt, now - startedAt >= Self.overall { return .incomplete }
        return .pending
    }
}

struct RemotePlayPairingTarget {
    let host: String
    let captureGeneration: UInt64
    func matches(host: String, captureGeneration: UInt64) -> Bool {
        self.host == host && self.captureGeneration == captureGeneration
    }
}
