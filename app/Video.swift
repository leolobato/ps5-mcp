// Video: records the picture and the console audio to an MP4 (H.264 + AAC) with AVAssetWriter.
//
// FrameSink hands every frame (and, from the capture card, every audio buffer) to the active VideoRecorder.
// The file starts at the first frame; audio that arrives before it is dropped. Frames and audio the encoder
// cannot take in time are dropped too, so a slow disk never stalls the capture queues. A capture card recording also
// gets the frame meter's numbers in a CSV with the same name.

import AVFoundation
import Foundation

final class VideoRecorder {
    let url: URL
    let started = uptimeSeconds()
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let audioFormat: CMFormatDescription?
    private var video: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audio: AVAssetWriterInput?
    private var sessionStarted = false
    private var finishing = false
    private var startTime = CMTime.invalid
    private var lastVideoTime = CMTime.invalid
    private(set) var frames = 0
    private let meterQueue = DispatchQueue(label: "frame-meter-csv", qos: .utility)
    private var meterFile: FileHandle?  // meterQueue only
    private var meterClosed = false  // meterQueue only: a late frame must not recreate a finished CSV

    /// The frame meter's CSV for the video at `url`.
    static func meterCSV(for url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("csv") }

    /// `audioFormat` is the capture card's audio (nil records the picture only).
    init(url: URL, audioFormat: CMFormatDescription?) throws {
        self.url = url
        self.audioFormat = audioFormat
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    }

    /// The writer's inputs need the frame size, so they are added on the first frame.
    private func setUp(width: Int, height: Int, at time: CMTime) -> Bool {
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 16_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
            ],
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return false }
        writer.add(video)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        self.video = video

        if let audioFormat, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee,
           (1...2).contains(asbd.mChannelsPerFrame) {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: asbd.mChannelsPerFrame,
                AVEncoderBitRateKey: asbd.mChannelsPerFrame == 1 ? 96_000 : 192_000,
            ], sourceFormatHint: audioFormat)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                self.audio = audio
            }
        }
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: time)
        startTime = time
        sessionStarted = true
        return true
    }

    /// A frame at `time` on the capture clock (the host clock for the camera-free sources).
    func append(_ buffer: CVPixelBuffer, at time: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard !finishing, writer.status != .failed else { return }
        if !sessionStarted {
            guard setUp(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), at: time)
            else { return }
        }
        // Timestamps must increase; a repeated one (two pushes in one clock tick) would fail the writer.
        guard let video, let adaptor, video.isReadyForMoreMediaData,
              !lastVideoTime.isValid || time > lastVideoTime else { return }
        if adaptor.append(buffer, withPresentationTime: time) {
            lastVideoTime = time
            frames += 1
        }
    }

    /// One row per captured frame, on the video's clock.
    func append(_ frame: FrameMeterFrame, at time: CMTime) {
        lock.lock()
        guard !finishing, sessionStarted else { lock.unlock(); return }
        let zero = startTime
        lock.unlock()
        func text(_ value: Double?, _ format: String) -> String { value.map { String(format: format, $0) } ?? "" }
        let row = "\(String(format: "%.6f", (time - zero).seconds)),\(frame.changed ? 1 : 0),"
            + "\(text(frame.frameTimeMs, "%.2f")),\(text(frame.fps, "%.2f")),\(frame.state.rawValue)\n"
        meterQueue.async { [self] in
            guard !meterClosed else { return }
            if meterFile == nil {
                let path = Self.meterCSV(for: url).path
                guard FileManager.default.createFile(atPath: path,
                                                     contents: Data("time_s,changed,frame_time_ms,fps,state\n".utf8)),
                      let file = FileHandle(forWritingAtPath: path) else { return }
                try? file.seekToEnd()
                meterFile = file
            }
            try? meterFile?.write(contentsOf: Data(row.utf8))
        }
    }

    /// Every row is on disk when this returns.
    private func closeMeterFile() {
        meterQueue.sync {
            meterClosed = true
            try? meterFile?.close()
            meterFile = nil
        }
    }

    func append(audio sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finishing, sessionStarted, writer.status == .writing, let audio, audio.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sample) >= startTime else { return }
        audio.append(sample)
    }

    /// Closes the file; `done` runs on the main queue with nil, or the reason nothing usable was written.
    func finish(_ done: @escaping (String?) -> Void) {
        lock.lock()
        finishing = true
        let started = sessionStarted, frames = frames
        lock.unlock()
        closeMeterFile()
        guard started, frames > 0, writer.status == .writing else {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: Self.meterCSV(for: url))
            let reason = writer.error?.localizedDescription ?? "no frames reached the recorder"
            DispatchQueue.main.async { done(reason) }
            return
        }
        video?.markAsFinished()
        audio?.markAsFinished()
        writer.endSession(atSourceTime: lastVideoTime)
        writer.finishWriting { [writer] in
            let reason = writer.status == .completed ? nil : writer.error?.localizedDescription ?? "unknown error"
            DispatchQueue.main.async { done(reason) }
        }
    }
}
