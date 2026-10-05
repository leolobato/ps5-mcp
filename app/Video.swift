// Video: records the picture and the console audio to an MP4 (H.264 + AAC) with AVAssetWriter.
//
// FrameSink hands every frame (and, from the capture card, every audio buffer) to the active VideoRecorder.
// The file starts at the first frame; audio that arrives before it is dropped. Frames and audio the encoder
// cannot take in time are dropped too, so a slow disk never stalls the capture queues.

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
        guard started, frames > 0, writer.status == .writing else {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
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
