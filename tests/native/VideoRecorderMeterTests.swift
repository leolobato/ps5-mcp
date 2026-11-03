import AVFoundation
import Foundation

func uptimeSeconds() -> Double { ProcessInfo.processInfo.systemUptime }

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

func wait(for recorder: VideoRecorder) -> String? {
    var finished = false
    var reason: String?
    recorder.finish { reason = $0; finished = true }
    let deadline = Date().addingTimeInterval(20)
    while !finished, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    require(finished, "the recorder finishes")
    return reason
}

@main struct VideoRecorderMeterTests {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixels)
        let buffer = pixels!

        // Rows land next to the video, on the video's clock, and are complete when finish reports.
        let url = folder.appendingPathComponent("video.mp4")
        let recorder = try VideoRecorder(url: url, audioFormat: nil)
        let frame = FrameMeterFrame(changed: true, frameTimeMs: 33.33, fps: 30, state: .measuring)
        let idle = FrameMeterFrame(changed: false, frameTimeMs: nil, fps: nil, state: .stillPicture)
        for index in 0..<10 {
            let time = CMTime(value: CMTimeValue(1000 + index), timescale: 60)
            recorder.append(buffer, at: time)
            recorder.append(index == 4 ? idle : frame, at: time)
        }
        require(wait(for: recorder) == nil, "the video is written")
        require(FileManager.default.fileExists(atPath: url.path), "the video exists")
        let csv = VideoRecorder.meterCSV(for: url)
        require(csv.lastPathComponent == "video.csv", "same name, csv extension")
        recorder.append(frame, at: CMTime(value: 1100, timescale: 60))  // a frame that was already on its way
        Thread.sleep(forTimeInterval: 0.1)
        let lines = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n").map(String.init)
        require(lines.first == "time_s,changed,frame_time_ms,fps,state", "header, got \(lines.first ?? "nothing")")
        require(lines.count == 11, "one row per frame, got \(lines.count)")
        require(lines[1] == "0.000000,1,33.33,30.00,measuring", "first row is time zero, got \(lines[1])")
        require(lines[5] == "0.066667,0,,,static", "empty values stay empty, got \(lines[5])")

        // Without rows (any source the meter does not run on), there is no CSV.
        let plainURL = folder.appendingPathComponent("plain.mp4")
        let plain = try VideoRecorder(url: plainURL, audioFormat: nil)
        plain.append(buffer, at: CMTime(value: 1, timescale: 60))
        plain.append(buffer, at: CMTime(value: 2, timescale: 60))
        require(wait(for: plain) == nil, "the plain video is written")
        require(!FileManager.default.fileExists(atPath: VideoRecorder.meterCSV(for: plainURL).path), "no rows, no CSV")

        // A recording that produced no video keeps no CSV either.
        let emptyURL = folder.appendingPathComponent("empty.mp4")
        let empty = try VideoRecorder(url: emptyURL, audioFormat: nil)
        empty.append(frame, at: .zero)  // before the first frame: dropped, as the video has no clock yet
        require(wait(for: empty) != nil, "an empty recording reports why")
        require(!FileManager.default.fileExists(atPath: VideoRecorder.meterCSV(for: emptyURL).path), "nothing left behind")
        print("recorder meter checks passed")
    }
}
