// FrameMeter: the game's frame rate and frame times, from which captured frames actually changed.
//
// The capture card delivers a fixed 60 fps, so a frame only counts when FrameDiffer sees it differ from the one
// before. Frame times are whole numbers of refresh periods, because a new picture can only appear on a new refresh.
// Frames lost on the Mac side are "no data": nothing is measured across them.

import Foundation

enum FrameMeterState: String {
    case starting, measuring
    case stillPicture = "static"
    case noSignal = "no_signal"
}

/// The meter's view of one captured frame.
struct FrameMeterFrame {
    let changed: Bool
    let frameTimeMs: Double?
    let fps: Double?
    let state: FrameMeterState
}

struct FrameMeterSample {
    /// When the frame appeared, on the capture clock.
    let time: Double
    let milliseconds: Double
}

struct FrameMeterReading {
    var state: FrameMeterState
    var fps: Double?
    var lowOnePercentFps: Double?
    let gaps: Int
    let refreshMs: Double
    let samples: [FrameMeterSample]
    /// The graph's right edge. It stops moving on a still picture, which pauses the graph.
    let now: Double

    var json: [String: Any] {
        func rounded(_ value: Double?) -> Any { value.map { ($0 * 100).rounded() / 100 } ?? NSNull() }
        return ["state": state.rawValue, "fps": rounded(fps), "low_1pct_fps": rounded(lowOnePercentFps), "gaps": gaps,
                "refresh_ms": rounded(refreshMs), "frame_times_ms": samples.suffix(120).map { rounded($0.milliseconds) }]
    }
}

/// One fixed-length measurement. All of it but `done` belongs to the meter's lock.
final class FrameMeterRun {
    let seconds: Double
    /// Signalled when `seconds` of signal have been counted.
    let done = DispatchSemaphore(value: 0)
    fileprivate var elapsed = 0.0
    fileprivate var complete = false
    fileprivate var seen = 0
    fileprivate var changes = 0
    fileprivate var still = 0.0
    fileprivate var gaps = 0
    /// Frame times are whole refreshes, so a count per length holds any run in a few entries.
    fileprivate var refreshes: [Int: Int] = [:]

    fileprivate init(seconds: Double) { self.seconds = seconds }
}

/// What a finished run found.
struct FrameMeterSummary {
    /// False when the signal did not last long enough to count the whole period.
    let complete: Bool
    let seconds: Double
    let stillSeconds: Double
    let state: FrameMeterState
    let fps: Double?
    let lowOnePercentFps: Double?
    let newFrames: Int
    let gaps: Int
    let refreshMs: Double
    /// Slowest last.
    let frameTimes: [(milliseconds: Double, count: Int)]

    var json: [String: Any] {
        func rounded(_ value: Double?) -> Any { value.map { ($0 * 100).rounded() / 100 } ?? NSNull() }
        return ["complete": complete, "seconds": rounded(seconds), "static_seconds": rounded(stillSeconds),
                "state": state.rawValue, "fps": rounded(fps), "low_1pct_fps": rounded(lowOnePercentFps),
                "new_frames": newFrames, "gaps": gaps, "refresh_ms": rounded(refreshMs),
                "frame_times": frameTimes.map { ["ms": rounded($0.milliseconds), "count": $0.count] }]
    }
}

final class FrameMeter {
    /// From calibration: repeated frames stayed below this and new frames above it on the capture card.
    static let threshold = 2.0
    /// Fewer changes than this in a second is a still picture. It is not zero: an on-screen counter still changes.
    static let stillBelow = 3
    private static let window = 1.0
    private static let history = 60.0
    /// A longer break than this is a new timeline (a signal dropout), not a late frame.
    private static let breakAfter = 1.0
    private static let learnedAfter = 10

    private let lock = NSLock()
    private var lastPTS: Double?
    private var lastChanged: Double?
    private var started = 0.0
    private var dropPending = false
    private var gaps = 0
    private var state = FrameMeterState.starting
    private var frozenAt: Double?
    private var period = 1.0 / 60
    private var deltas: [Double] = []
    private var deltaCount = 0
    private var recent: [(pts: Double, changed: Bool)] = []
    private var recentHead = 0
    private var changedInWindow = 0
    private var samples: [FrameMeterSample] = []
    private var samplesHead = 0
    private var low: Double?
    private var lowAt = -Double.infinity
    private var runs: [FrameMeterRun] = []

    /// Forget everything, as when the meter is turned on or the source changes.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        gaps = 0
        period = 1.0 / 60
        deltas.removeAll(keepingCapacity: true)
        deltaCount = 0
        restart()
    }

    /// Starts counting. It outlasts `reset()`, so a signal dropout costs the run time rather than its numbers.
    func begin(seconds: Double) -> FrameMeterRun {
        let run = FrameMeterRun(seconds: seconds)
        lock.lock(); runs.append(run); lock.unlock()
        return run
    }

    /// Stops counting, whether or not the period ended.
    func finish(_ run: FrameMeterRun) -> FrameMeterSummary {
        lock.lock(); defer { lock.unlock() }
        runs.removeAll { $0 === run }
        let moving = run.seen > 0
        var state = FrameMeterState.noSignal
        if moving { state = .measuring } else if run.still > 0 { state = .stillPicture }
        let lengths = run.refreshes.keys.sorted()
        let count = run.refreshes.values.reduce(0, +)
        var low: Double?
        if count >= 100 {
            var left = count * 99 / 100
            for length in lengths {
                left -= run.refreshes[length]!
                if left < 0 { low = 1 / (Double(length) * period); break }
            }
        }
        return FrameMeterSummary(complete: run.complete, seconds: run.elapsed, stillSeconds: run.still, state: state,
                                 fps: moving ? Double(run.changes) / (Double(run.seen) * period) : nil,
                                 lowOnePercentFps: low, newFrames: run.changes, gaps: run.gaps,
                                 refreshMs: period * 1000,
                                 frameTimes: lengths.map { (Double($0) * period * 1000, run.refreshes[$0]!) })
    }

    /// A frame was lost before it reached the app.
    func noteDrop() {
        lock.lock(); dropPending = true; lock.unlock()
    }

    /// `difference` is nil when there is nothing to compare with.
    @discardableResult
    func add(pts: Double, difference: FrameDifference?) -> FrameMeterFrame {
        lock.lock(); defer { lock.unlock() }
        guard pts.isFinite else { return FrameMeterFrame(changed: false, frameTimeMs: nil, fps: nil, state: state) }
        var step = 0.0
        if let last = lastPTS {
            let delta = pts - last
            step = delta
            if delta <= 0 || delta > Self.breakAfter {
                noteGap()
                restart()
                lastPTS = pts
                started = pts
                return FrameMeterFrame(changed: false, frameTimeMs: nil, fps: nil, state: state)
            }
            learn(delta)
            if dropPending || (deltaCount >= Self.learnedAfter && delta > period * 1.5) {
                noteGap()
                lastChanged = nil
            }
        } else {
            started = pts
        }
        dropPending = false
        lastPTS = pts

        let changed = (difference?.largestBlock ?? 0) > Self.threshold
        slideWindow(to: pts, changed: changed)
        let full = pts - started >= Self.window
        if full {
            if changedInWindow < Self.stillBelow {
                if state != .stillPicture {
                    frozenAt = pts
                    recountWindowAsStill()
                }
                state = .stillPicture
                lastChanged = nil
            } else {
                state = .measuring
                frozenAt = nil
            }
        }
        var frameTime: Double?
        var length: Int?
        if changed, state != .stillPicture {
            if let lastChanged {
                let refreshes = max(1, ((pts - lastChanged) / period).rounded())
                let milliseconds = refreshes * period * 1000
                frameTime = milliseconds
                length = Int(refreshes)
                samples.append(FrameMeterSample(time: pts, milliseconds: milliseconds))
                trimSamples(before: pts - Self.history)
            }
            lastChanged = pts
        }
        count(step: step, changed: changed, length: length)
        return FrameMeterFrame(changed: changed, frameTimeMs: frameTime, fps: state == .measuring ? currentFps() : nil,
                               state: state)
    }

    /// The trailing `seconds` of frame times, and the current numbers.
    func reading(seconds: Double = 10) -> FrameMeterReading {
        lock.lock(); defer { lock.unlock() }
        let now = frozenAt ?? lastPTS ?? 0
        var first = samples.count
        while first > samplesHead, samples[first - 1].time >= now - seconds { first -= 1 }
        return FrameMeterReading(state: state, fps: state == .measuring ? currentFps() : nil,
                                 lowOnePercentFps: lowOnePercent(at: now), gaps: gaps, refreshMs: period * 1000,
                                 samples: Array(samples[first...]), now: now)
    }

    private func noteGap() {
        gaps += 1
        for run in runs { run.gaps += 1 }
    }

    /// The meter's first second cannot tell a still picture from a slow one, so a run starts after it.
    private func count(step: Double, changed: Bool, length: Int?) {
        guard state != .starting else { return }
        for run in runs where !run.complete {
            run.elapsed += step
            if state == .stillPicture {
                run.still += step
            } else {
                run.seen += 1
                if changed { run.changes += 1 }
                if let length { run.refreshes[length, default: 0] += 1 }
            }
            if run.elapsed >= run.seconds {
                run.complete = true
                run.done.signal()
            }
        }
    }

    /// A still picture is only known a second late. That second belongs to it, not to the runs' average.
    private func recountWindowAsStill() {
        for run in runs where !run.complete {
            let frames = min(run.seen, recent.count - recentHead)
            run.seen -= frames
            run.changes -= min(run.changes, changedInWindow)
            run.still += Double(frames) * period
        }
    }

    private func restart() {
        lastPTS = nil
        lastChanged = nil
        started = 0
        dropPending = false
        state = .starting
        frozenAt = nil
        recent.removeAll(keepingCapacity: true)
        recentHead = 0
        changedInWindow = 0
        samples.removeAll(keepingCapacity: true)
        samplesHead = 0
        low = nil
        lowAt = -.infinity
    }

    /// The median is immune to the odd late or lost frame, and works for any refresh rate.
    private func learn(_ delta: Double) {
        if deltas.count < 121 { deltas.append(delta) } else { deltas[deltaCount % 121] = delta }
        deltaCount += 1
        if deltaCount == Self.learnedAfter || deltaCount % 30 == 0 {
            period = deltas.sorted()[deltas.count / 2]
        }
    }

    private func slideWindow(to pts: Double, changed: Bool) {
        recent.append((pts, changed))
        if changed { changedInWindow += 1 }
        while recent[recentHead].pts <= pts - Self.window {
            if recent[recentHead].changed { changedInWindow -= 1 }
            recentHead += 1
        }
        if recentHead > 600 {
            recent.removeFirst(recentHead)
            recentHead = 0
        }
    }

    /// Changes per frame actually seen, scaled to the refresh rate, so that lost frames do not read as a slow game.
    private func currentFps() -> Double {
        let seen = recent.count - recentHead
        return seen > 0 ? Double(changedInWindow) / (Double(seen) * period) : 0
    }

    private func trimSamples(before time: Double) {
        while samplesHead < samples.count, samples[samplesHead].time < time { samplesHead += 1 }
        if samplesHead > 600 {
            samples.removeFirst(samplesHead)
            samplesHead = 0
        }
    }

    /// Sorting a minute of samples is not free, and a figure this slow-moving need not update every frame.
    private func lowOnePercent(at now: Double) -> Double? {
        guard now - lowAt >= 0.5 || now < lowAt else { return low }
        lowAt = now
        let times = samples[samplesHead...].map(\.milliseconds).sorted()
        low = times.count >= 100 ? 1000 / times[times.count * 99 / 100] : nil
        return low
    }
}
