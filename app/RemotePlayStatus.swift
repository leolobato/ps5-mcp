import Foundation

struct RemotePlayStatus {
    enum Phase: String {
        case stopped, connecting, streaming, reconnecting, unavailable
        case applyingAdmission = "applying_admission"
        case waitingForVideo = "waiting_for_video"
        case setupNeeded = "setup_needed"
    }
    var phase: Phase = .stopped
    var issue: String?
    var reconnects = 0
    var videoReady = false
    var audioReady = false
    var width = 0
    var height = 0
    var generation = 0
    var admission = "not_attempted"
    var keyboardEnabled = false
    var keyboardOpen = false

    var summary: String {
        if let issue { return issue }
        switch phase {
        case .streaming:
            return "Streaming · \(width) × \(height) · " + (audioReady ? "Audio receiving" : "Waiting for audio")
        case .stopped: return "Remote Play stopped."
        case .setupNeeded: return "Set up Remote Play to receive video and audio."
        case .applyingAdmission: return "Preparing Remote Play for this PS5 session…"
        case .waitingForVideo: return "Connected; waiting for video…"
        case .connecting: return "Connecting to PS5…"
        case .reconnecting: return "Connection lost. Retrying…"
        case .unavailable: return "Remote Play unavailable."
        }
    }
    var json: [String: Any] {
        ["state": phase.rawValue, "error": issue as Any? ?? NSNull(), "reconnects": reconnects,
         "video_ready": videoReady, "audio_ready": audioReady, "width": width, "height": height,
         "generation": generation, "admission": admission,
         "keyboard": ["enabled": keyboardEnabled, "open": keyboardOpen]]
    }
}
