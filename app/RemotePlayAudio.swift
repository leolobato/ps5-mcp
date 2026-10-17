import AVFoundation
import Foundation

/// Int16 interleaved PCM from Chiaki. Submit/reset run on the source's media queue;
/// setMuted may also run on the UI queue. Muting only affects local playback.
final class RemotePlayAudio {
    private let onSample: (CMSampleBuffer) -> Void
    private let lock = NSRecursiveLock()
    private var muted = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var playbackFailed = false
    private let pending = PendingPlayback()
    private var epoch: CMTime?
    private var totalFrames: Int64 = 0
    private var lastSampleEnd: CMTime?
    private var sampleRate = 0
    private var channelCount = 0

    private final class PendingPlayback {
        let lock = NSLock()
        var generation: UInt64 = 0
        var frames = 0
        func clear() { lock.lock(); generation &+= 1; frames = 0; lock.unlock() }
        func reserve(_ count: Int, limit: Int) -> UInt64? {
            lock.lock(); defer { lock.unlock() }
            guard count <= limit - frames else { return nil }
            frames += count
            return generation
        }
        func complete(_ count: Int, generation: UInt64) {
            lock.lock(); defer { lock.unlock() }
            if generation == self.generation { frames -= count }
        }
    }

    init(onSample: @escaping (CMSampleBuffer) -> Void) { self.onSample = onSample }
    deinit { reset() }

    func setMuted(_ muted: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.muted = muted
        if muted { stopPlayback() }
        else { playbackFailed = false }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        stopPlayback()
        playbackFailed = false
        epoch = nil
        totalFrames = 0
        lastSampleEnd = nil
        sampleRate = 0
        channelCount = 0
    }

    func submit(_ pcm: Data, samplesPerChannel: Int, channels: Int, rate: Int, at time: CMTime) {
        lock.lock(); defer { lock.unlock() }
        // Bound individual packets as well as the playback queue; reject overflow before multiplying.
        guard time.isNumeric, (8_000...192_000).contains(rate), (1...8).contains(channels),
              samplesPerChannel > 0, samplesPerChannel <= rate / 5,
              pcm.count == samplesPerChannel * channels * 2 else { return }
        if rate != sampleRate || channels != channelCount {
            stopPlayback()
            sampleRate = rate
            channelCount = channels
            epoch = nil
            playbackFailed = false
        }
        var presentation = epoch.map { CMTimeAdd($0, CMTime(value: totalFrames, timescale: Int32(rate))) } ?? time
        if let lastSampleEnd, CMTimeCompare(presentation, lastSampleEnd) < 0 {
            presentation = lastSampleEnd
        }
        // Preserve cumulative sample pacing through packet-arrival jitter. A burst may put
        // the next sample ahead of the host clock: drop excess packets until the clock
        // catches up, without rewinding or overlapping audio already sent to recording.
        let drift = CMTimeGetSeconds(CMTimeSubtract(presentation, time))
        if drift > 0.1 {
            stopPlayback()
            return
        }
        // A forward discontinuity can safely move the epoch to the host clock. Format
        // changes may establish an epoch at the previous format's end to avoid overlap.
        if epoch == nil || drift < -0.1 {
            stopPlayback()
            presentation = CMTimeMaximum(time, presentation)
            epoch = presentation
            totalFrames = 0
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 2), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * 2), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr, let format else { return }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: pcm.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: pcm.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        guard pcm.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
            offsetIntoDestination: 0, dataLength: pcm.count) }) == noErr else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                       presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
        var size = channels * 2
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: samplesPerChannel, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        totalFrames += Int64(samplesPerChannel)
        lastSampleEnd = CMTimeAdd(presentation, CMTime(value: Int64(samplesPerChannel), timescale: Int32(rate)))
        onSample(sample)
        guard !muted, !playbackFailed else { return }
        play(pcm, frames: samplesPerChannel, channels: channels, rate: rate)
    }

    private func stopPlayback() {
        pending.clear()
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        playbackFormat = nil
    }

    private func play(_ pcm: Data, frames: Int, channels: Int, rate: Int) {
        if engine == nil {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: UInt32(channels)) else { return }
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let output = engine.outputNode.outputFormat(forBus: 0)
            guard output.sampleRate > 0, output.channelCount > 0 else { playbackFailed = true; return }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do { try engine.start() }
            catch { engine.stop(); playbackFailed = true; return }
            player.play()
            self.engine = engine
            self.player = player
            playbackFormat = format
        }
        guard let player, let format = playbackFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)),
              let output = buffer.floatChannelData else { return }
        buffer.frameLength = UInt32(frames)
        pcm.withUnsafeBytes { bytes in
            let input = bytes.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let offset = (frame * channels + channel) * 2
                    let value = Int16(bitPattern: UInt16(input[offset]) | UInt16(input[offset + 1]) << 8)
                    output[channel][frame] = Float(value) / 32768
                }
            }
        }
        // Keep at most 200ms scheduled. On overload discard stale playback immediately;
        // recordings already received the original PCM sample above.
        var generation = pending.reserve(frames, limit: rate / 5)
        if generation == nil {
            pending.clear()
            player.stop()
            player.play()
            generation = pending.reserve(frames, limit: rate / 5)
        }
        guard let generation else { return }
        let pending = self.pending
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            pending.complete(frames, generation: generation)
        }
    }
}
