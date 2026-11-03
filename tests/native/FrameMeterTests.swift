import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

func near(_ value: Double?, _ expected: Double, _ tolerance: Double = 0.01) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

let refresh = 1.0 / 60
let new = FrameDifference(mean: 8, largestBlock: 30, rows: [])
let repeated = FrameDifference(mean: 0.1, largestBlock: 1.5, rows: [])

/// Feeds whole seconds of a repeating pattern, X for a new frame. Returns the frames.
@discardableResult
func feed(_ meter: FrameMeter, _ pattern: String, seconds: Double, from start: inout Double) -> [FrameMeterFrame] {
    let marks = Array(pattern)
    let count = Int(seconds * 60)
    var out: [FrameMeterFrame] = []
    for index in 0..<count {
        out.append(meter.add(pts: start, difference: marks[index % marks.count] == "X" ? new : repeated))
        start += refresh
    }
    return out
}

@main struct FrameMeterTests {
    static func main() {
        for (pattern, fps, milliseconds) in [("X", 60.0, 16.67), ("X.", 30.0, 33.33), ("X..", 20.0, 50.0)] {
            let meter = FrameMeter()
            var time = 100.0
            feed(meter, pattern, seconds: 3, from: &time)
            let reading = meter.reading()
            require(reading.state == .measuring, "\(pattern) is measured")
            require(near(reading.fps, fps, 0.5), "\(pattern) reads \(fps) fps, got \(String(describing: reading.fps))")
            require(reading.samples.allSatisfy { near($0.milliseconds, milliseconds) }, "\(pattern) has one frame time")
            require(reading.gaps == 0, "a steady signal has no gaps")
        }

        // A hitch in a 30 fps run is one long frame among 33.3 ms frames: the repeat that ends the pattern, four more
        // and the new frame make six refreshes.
        var meter = FrameMeter()
        var time = 0.0
        feed(meter, "X.", seconds: 2, from: &time)
        feed(meter, "....", seconds: 4.0 / 60, from: &time)
        feed(meter, "X.", seconds: 2, from: &time)
        let hitch = meter.reading().samples.map(\.milliseconds)
        require(hitch.filter { near($0, 100) }.count == 1, "one long frame, got \(Array(Set(hitch)))")
        require(hitch.filter { near($0, 33.33) }.count == hitch.count - 1, "the rest are unchanged")

        // Noise below the threshold never counts, and a change in one block does.
        meter = FrameMeter()
        time = 0
        let barely = FrameDifference(mean: 0.2, largestBlock: FrameMeter.threshold, rows: [])
        require(!meter.add(pts: time, difference: barely).changed, "the threshold itself is noise")
        let small = FrameDifference(mean: 0.05, largestBlock: FrameMeter.threshold + 0.1, rows: [])
        require(meter.add(pts: time + refresh, difference: small).changed, "one block is enough")

        // A gap in the timestamps is no data: not a long frame.
        meter = FrameMeter()
        time = 0
        feed(meter, "X", seconds: 1, from: &time)
        time += refresh * 3
        feed(meter, "X", seconds: 1, from: &time)
        var gapped = meter.reading()
        require(gapped.gaps == 1, "one gap, got \(gapped.gaps)")
        require(gapped.samples.allSatisfy { near($0.milliseconds, 16.67) }, "no frame time spans the gap")

        // A frame the capture session dropped is the same.
        meter = FrameMeter()
        time = 0
        feed(meter, "X", seconds: 1, from: &time)
        meter.noteDrop()
        feed(meter, "X", seconds: 1, from: &time)
        gapped = meter.reading()
        require(gapped.gaps == 1, "a drop is a gap, got \(gapped.gaps)")
        require(near(gapped.fps, 60, 0.5), "lost frames do not lower the frame rate")

        // A still picture: stops measuring, keeps the graph moving, and survives an on-screen counter changing each second.
        meter = FrameMeter()
        time = 0
        feed(meter, "X.", seconds: 2, from: &time)
        let before = meter.reading().samples.count
        var pattern = "X" + String(repeating: ".", count: 59)
        feed(meter, pattern, seconds: 5, from: &time)
        let still = meter.reading()
        require(still.state == .stillPicture, "a counter ticking on a still screen reads static")
        require(still.fps == nil, "a still picture has no frame rate")
        require(still.samples.count <= before + 30, "the graph stops gaining samples")
        require(still.now > time - 0.1, "the graph's clock keeps running")
        let longest = still.samples.map(\.milliseconds).max() ?? 0
        feed(meter, pattern, seconds: 11, from: &time)
        require(meter.reading().samples.isEmpty, "the old line scrolls off the graph")
        require(longest < 100, "the wait is not a frame time, got \(longest)")
        feed(meter, "X.", seconds: 2, from: &time)
        let recovered = meter.reading()
        require(recovered.state == .measuring && near(recovered.fps, 30, 0.5), "motion resumes the meter")
        require((recovered.samples.map(\.milliseconds).max() ?? 0) < 100, "nor is the first frame after it")

        // A signal dropout starts a new timeline, with no spike.
        meter = FrameMeter()
        time = 0
        feed(meter, "X", seconds: 2, from: &time)
        time += 8
        require(meter.add(pts: time, difference: new).state == .starting, "a dropout restarts the meter")
        time += refresh
        feed(meter, "X", seconds: 2, from: &time)
        let resumed = meter.reading()
        require(resumed.samples.allSatisfy { near($0.milliseconds, 16.67) }, "no spike after a dropout")
        require(resumed.gaps == 1, "the dropout is counted")

        // The refresh period is measured: 59.94 Hz with jitter still gives clean steps.
        meter = FrameMeter()
        time = 0
        var jitter: UInt64 = 7
        for index in 0..<600 {
            jitter = jitter &* 6364136223846793005 &+ 1442695040888963407
            let wobble = (Double(jitter >> 56) / 255 - 0.5) * 0.002
            meter.add(pts: time + wobble, difference: index % 2 == 0 ? new : repeated)
            time += 1001.0 / 60000
        }
        let measured = meter.reading()
        require(near(measured.refreshMs, 16.683, 0.2), "59.94 Hz is learned, got \(measured.refreshMs)")
        require(measured.gaps == 0, "jitter is not a gap")
        let late = measured.samples.suffix(100).map(\.milliseconds)
        require(late.allSatisfy { near($0, measured.refreshMs * 2, 3) }, "jitter rounds to whole refreshes")

        // A 30 fps source (the development sources): every frame changes, and it is 30 fps, with no gaps.
        meter = FrameMeter()
        time = 0
        for _ in 0..<150 {
            meter.add(pts: time, difference: new)
            time += 1.0 / 30
        }
        let slowSource = meter.reading()
        require(near(slowSource.fps, 30, 0.5) && slowSource.gaps == 0, "the refresh rate comes from the source")

        // The 1% low is the slow end of the frame times.
        meter = FrameMeter()
        time = 0
        feed(meter, "X", seconds: 8, from: &time)
        for _ in 0..<12 { feed(meter, "X..", seconds: 3.0 / 60, from: &time) }
        feed(meter, "X", seconds: 2, from: &time)
        let lows = meter.reading()
        require(near(lows.lowOnePercentFps, 20, 0.5), "1% low follows the slowest frames, got \(String(describing: lows.lowOnePercentFps))")

        // Reset forgets the lot, and the first frame has no difference to report.
        meter.reset()
        let empty = meter.reading()
        require(empty.state == .starting && empty.samples.isEmpty && empty.gaps == 0, "reset clears the meter")
        let first = meter.add(pts: 5, difference: nil)
        require(!first.changed && first.frameTimeMs == nil, "the first frame measures nothing")
        require(!meter.add(pts: .nan, difference: new).changed, "a bad timestamp is ignored")

        // A fixed period counts only its own frames, starts after the meter's first second, and does not stop at the
        // meter's 60 seconds of history.
        meter = FrameMeter()
        time = 0
        var run = meter.begin(seconds: 90)
        feed(meter, "X.", seconds: 1, from: &time)
        feed(meter, "X.", seconds: 45, from: &time)
        feed(meter, "X..", seconds: 44, from: &time)
        require(run.done.wait(timeout: .now()) == .timedOut, "the first second does not count")
        feed(meter, "X..", seconds: 1.1, from: &time)
        require(run.done.wait(timeout: .now()) == .success, "the run ends after its period")
        feed(meter, "X", seconds: 5, from: &time) // after the end: must not count
        var summary = meter.finish(run)
        require(summary.complete && near(summary.seconds, 90, 0.05), "ran 90 s, got \(summary.seconds)")
        require(near(summary.fps, 25, 0.5), "half at 30 and half at 20 fps, got \(String(describing: summary.fps))")
        require(summary.state == .measuring && summary.stillSeconds == 0 && summary.gaps == 0, "steady and moving")
        require(near(summary.lowOnePercentFps, 20, 0.5), "1% low is the slower half")
        let lengths = summary.frameTimes.map(\.milliseconds)
        require(lengths.count >= 2 && near(lengths[0], 33.33) && near(lengths.last, 50), "\(lengths)")
        require(summary.frameTimes.map(\.count).reduce(0, +) > 1800, "every frame time is kept past the 60 s history")

        // A still picture is reported apart and does not lower the average.
        meter = FrameMeter()
        time = 0
        run = meter.begin(seconds: 6)
        feed(meter, "X.", seconds: 3, from: &time)
        feed(meter, ".", seconds: 3, from: &time)
        feed(meter, "X.", seconds: 2, from: &time)
        summary = meter.finish(run)
        require(summary.complete && summary.state == .measuring, "part moving is still measured")
        require(near(summary.stillSeconds, 3, 0.2), "three seconds still, got \(summary.stillSeconds)")
        require(near(summary.fps, 30, 1), "the still part does not lower the average, got \(String(describing: summary.fps))")

        meter = FrameMeter()
        time = 0
        run = meter.begin(seconds: 3)
        feed(meter, ".", seconds: 5, from: &time)
        summary = meter.finish(run)
        require(summary.state == .stillPicture && summary.fps == nil && summary.frameTimes.isEmpty, "all still")

        // No signal, and a signal that ends early, report what they have.
        meter = FrameMeter()
        summary = meter.finish(meter.begin(seconds: 5))
        require(!summary.complete && summary.state == .noSignal && summary.fps == nil, "nothing was counted")
        require(summary.lowOnePercentFps == nil && JSONSerialization.isValidJSONObject(summary.json), "valid when empty")

        // A dropout costs the time it lasted, and keeps what was counted before it.
        meter = FrameMeter()
        time = 0
        run = meter.begin(seconds: 4)
        feed(meter, "X.", seconds: 3, from: &time)
        meter.reset()
        time += 5
        feed(meter, "X.", seconds: 2, from: &time)
        require(run.done.wait(timeout: .now()) == .timedOut, "only three seconds counted so far")
        feed(meter, "X.", seconds: 2.2, from: &time)
        summary = meter.finish(run)
        require(summary.complete && near(summary.seconds, 4, 0.05), "ran 4 s of signal, got \(summary.seconds)")
        require(near(summary.fps, 30, 0.5), "the dropout does not read as slow, got \(String(describing: summary.fps))")

        // Two runs at once count separately.
        meter = FrameMeter()
        time = 0
        let long = meter.begin(seconds: 4)
        feed(meter, "X", seconds: 2, from: &time)
        let short = meter.begin(seconds: 1)
        feed(meter, "X.", seconds: 3.1, from: &time)
        require(near(meter.finish(short).fps, 30, 0.5), "the second run saw only 30 fps")
        require((meter.finish(long).fps ?? 0) > 35, "the first run saw both")

        // The API shape.
        pattern = "X."
        time = 0
        meter = FrameMeter()
        feed(meter, pattern, seconds: 2, from: &time)
        let json = meter.reading().json
        require(json["state"] as? String == "measuring", "state is in the JSON")
        require((json["frame_times_ms"] as? [Any])?.isEmpty == false, "frame times are in the JSON")
        require(JSONSerialization.isValidJSONObject(json), "the reading is valid JSON")
        print("frame meter checks passed")
    }
}
