import AVFoundation
import CoreVideo
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

func centerPixel(_ buffer: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        + 540 * CVPixelBufferGetBytesPerRow(buffer) + 960 * 4
    return Array(UnsafeBufferPointer(start: p, count: 4))
}

@main struct MediaTests {
    static func main() throws {
        let red = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let blue = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let dependent = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let time = CMTime(value: 120_000, timescale: 600)
        var frames: [(CVPixelBuffer, CMTime)] = []
        let decoder = RemotePlayDecoder { frames.append(($0, $1)) }
        for bad in [Data(), Data([1, 2, 3]), Data([0, 0, 1]), Data([0, 0, 1, 0x80]),
                    Data([0, 0, 1, 0x67, 0]), Data([0, 0, 1, 0x65, 0])] {
            require(!decoder.submit(bad, at: time), "accepted invalid Annex B / unconfigured slice")
        }
        require(frames.isEmpty, "invalid input produced frames")
        require(decoder.submit(red, at: time), "failed to decode generated 720p H.264")
        require(frames.count == 1, "decode must complete synchronously")
        require(CVPixelBufferGetWidth(frames[0].0) == 1920, "720p was not scaled to 1920")
        require(CVPixelBufferGetHeight(frames[0].0) == 1080, "720p was not scaled to 1080")
        require(CVPixelBufferGetPixelFormatType(frames[0].0) == kCVPixelFormatType_32BGRA, "sink needs BGRA")
        require(CMTimeCompare(frames[0].1, time) == 0, "video lost the host timestamp")
        let redPixel = centerPixel(frames[0].0)
        require(redPixel[2] > 220 && redPixel[0] < 30 && redPixel[1] < 30, "BGRA channels/color incorrect")
        let next = CMTimeAdd(time, CMTime(value: 1, timescale: 60))
        require(decoder.submit(blue, at: next), "SPS/PPS/resolution change failed")
        require(frames.count == 2, "format change lost frame")
        let bluePixel = centerPixel(frames[1].0)
        require(bluePixel[0] > 220 && bluePixel[2] < 30, "new format did not produce blue BGRA")
        decoder.reset()
        require(frames.count == 2, "reset emitted a delayed frame")
        require(!decoder.submit(Data([0, 0, 1, 0x41, 1]), at: next), "reset retained decoding parameters")
        require(decoder.submit(red, at: next), "decoder did not restart after reset")
        require(frames.count == 3, "restart lost frame")

        // Split the generated stream at its second access-unit delimiter. This keeps real
        // dependent P-slices intact, including all of x264's sliced-thread NAL units.
        let bytes = [UInt8](dependent)
        let delimiters = (0..<(bytes.count - 4)).filter {
            bytes[$0] == 0 && bytes[$0 + 1] == 0 && bytes[$0 + 2] == 0 &&
            bytes[$0 + 3] == 1 && bytes[$0 + 4] & 0x1f == 9
        }
        require(delimiters.count == 2, "fixture should contain IDR and dependent access units")
        let idr = dependent.prefix(delimiters[1])
        let pFrame = dependent.suffix(from: delimiters[1])
        decoder.reset()
        require(decoder.submit(idr, at: time), "generated multi-NAL IDR failed")
        require(decoder.submit(pFrame, at: next), "valid dependent P-frame failed")
        require(!decoder.submit(Data([0, 0, 1, 0xe5, 1]), at: next), "forbidden NAL header accepted")
        let countAfterLoss = frames.count
        require(!decoder.submit(pFrame, at: next), "corruption did not require a recovery IDR")
        require(frames.count == countAfterLoss, "corrupt dependency chain delivered a frame")
        require(decoder.submit(idr, at: next), "recovery IDR failed")
        decoder.reset()
        require(!decoder.submit(pFrame, at: next), "reset allowed old dependent frames")

        // Annex B allows both start-code widths and parameter sets arriving separately.
        let redBytes = [UInt8](red)
        var threeByteCodes = Data()
        var offset = 0
        while offset < redBytes.count {
            if offset + 3 < redBytes.count && Array(redBytes[offset..<(offset + 4)]) == [0, 0, 0, 1] {
                threeByteCodes.append(contentsOf: [0, 0, 1])
                offset += 4
            } else { threeByteCodes.append(redBytes[offset]); offset += 1 }
        }
        require(decoder.submit(threeByteCodes, at: next), "3-byte Annex B start codes failed")
        require(!decoder.submit(Data([0, 0, 1, 0x65, 0x80]), at: next), "invalid configured slice accepted")
        require(decoder.submit(red, at: next), "valid IDR did not recover after decode failure")
        decoder.reset()
        let firstSlice = (0..<(redBytes.count - 3)).first {
            redBytes[$0] == 0 && redBytes[$0 + 1] == 0 && redBytes[$0 + 2] == 1 &&
            redBytes[$0 + 3] & 0x1f == 5
        }!
        let sliceStart = redBytes[firstSlice - 1] == 0 ? firstSlice - 1 : firstSlice
        let parameterSets = red.prefix(sliceStart)
        let slices = red.suffix(from: sliceStart)
        let beforeParameters = frames.count
        require(decoder.submit(parameterSets, at: time), "separate SPS/PPS access unit failed")
        require(frames.count == beforeParameters, "parameter sets produced a picture")
        require(decoder.submit(slices, at: time), "separate IDR did not use cached SPS/PPS")
        require(frames.count == beforeParameters + 1, "separate IDR lost frame")
        decoder.reset()
        frames.removeAll()
        var bounded = false
        // Model a downstream consumer retaining buffers indefinitely. The decoder must
        // refuse additional scaled allocations instead of growing with stream duration.
        for _ in 0..<16 {
            if !decoder.submit(red, at: next) { bounded = true; break }
        }
        require(bounded, "scaled output allocation grew without a bound")
        frames.removeAll()
        require(decoder.submit(red, at: next), "decoder did not recover when output buffers were released")
        decoder.reset()
        require(!decoder.submit(red, at: .invalid), "invalid video timestamp accepted")

        var samples: [CMSampleBuffer] = []
        let audio = RemotePlayAudio { samples.append($0) }
        audio.setMuted(true) // headless/closed-window mode must still feed recording
        let pcm = Data(repeating: 0x2a, count: 480 * 2 * 2)
        audio.submit(pcm, samplesPerChannel: 480, channels: 2, rate: 48_000, at: time)
        require(samples.count == 1, "muted audio did not reach recording")
        require(CMSampleBufferGetNumSamples(samples[0]) == 480, "wrong PCM frame count")
        let format = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(samples[0])!)!.pointee
        require(format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 16 &&
                format.mChannelsPerFrame == 2 && format.mSampleRate == 48_000 &&
                format.mBytesPerFrame == 4 && format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                "wrong signed int16 interleaved PCM format")
        require(format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0, "PCM must be signed")
        require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(samples[0]), time) == 0, "wrong audio epoch")
        // Small packet-arrival jitter must not introduce gaps into the recording's sample timeline.
        audio.submit(pcm, samplesPerChannel: 480, channels: 2, rate: 48_000,
                     at: CMTimeAdd(time, CMTime(value: 12, timescale: 1000)))
        require(samples.count == 2, "second PCM packet lost")
        require(abs(CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(samples[1]), time)) - 0.01) < 0.000001,
                "packet jitter changed audio pacing")
        var copied = Data(count: pcm.count)
        let block = CMSampleBufferGetDataBuffer(samples[0])!
        let status = copied.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: pcm.count, destination: $0.baseAddress!) }
        require(status == noErr && copied == pcm, "recording PCM bytes changed")
        for (frames, channels, rate, data) in [(0, 2, 48_000, pcm), (480, 0, 48_000, pcm),
            (480, 2, 0, pcm), (480, 2, 48_000, Data([1])), (Int.max, 2, 48_000, pcm)] {
            audio.submit(data, samplesPerChannel: frames, channels: channels, rate: rate, at: time)
        }
        require(samples.count == 2, "invalid PCM delivered")
        audio.submit(pcm, samplesPerChannel: 480, channels: 2, rate: 48_000, at: .invalid)
        require(samples.count == 2, "invalid audio timestamp delivered")
        audio.reset()
        let restart = CMTime(value: 300, timescale: 1)
        audio.submit(pcm, samplesPerChannel: 480, channels: 2, rate: 48_000, at: restart)
        require(samples.count == 3 && CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(samples[2]), restart) == 0,
                "audio reset retained the old epoch")
        // Large clock drift/discontinuity must re-anchor instead of recording arbitrarily stale audio.
        audio.submit(pcm, samplesPerChannel: 480, channels: 2, rate: 48_000, at: CMTime(value: 301, timescale: 1))
        require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(samples[3]), CMTime(value: 301, timescale: 1)) == 0,
                "audio did not bound clock drift")
        audio.submit(Data(repeating: 0, count: 441 * 2), samplesPerChannel: 441, channels: 1, rate: 44_100,
                     at: CMTime(value: 302, timescale: 1))
        let mono = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(samples[4])!)!.pointee
        require(mono.mChannelsPerFrame == 1 && mono.mSampleRate == 44_100 && mono.mBytesPerFrame == 2,
                "audio format change retained old sample format")
        require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(samples[4]), CMTime(value: 302, timescale: 1)) == 0,
                "audio format change retained old clock")
        audio.reset()

        // Backlogged 10ms packets can arrive only 0.1ms apart. Arrival-clock drift
        // must never reset recording PTS behind an already delivered sample's end.
        var burstSamples: [CMSampleBuffer] = []
        let burstAudio = RemotePlayAudio { burstSamples.append($0) }
        burstAudio.setMuted(true)
        for packet in 0..<15 {
            burstAudio.submit(pcm, samplesPerChannel: 480, channels: 2, rate: 48_000,
                              at: CMTime(value: 2_000_000 + Int64(packet), timescale: 10_000))
        }
        require(!burstSamples.isEmpty, "burst discarded all audio")
        for index in 1..<burstSamples.count {
            let previousEnd = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(burstSamples[index - 1]),
                                        CMSampleBufferGetDuration(burstSamples[index - 1]))
            require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(burstSamples[index]), previousEnd) >= 0,
                    "burst re-anchoring moved recording audio backwards or overlapped samples")
        }
        let burstLastPTS = CMSampleBufferGetPresentationTimeStamp(burstSamples.last!)
        require(CMTimeGetSeconds(CMTimeSubtract(burstLastPTS, CMTime(value: 2_000_014, timescale: 10_000))) <= 0.1,
                "burst left the audio timeline unbounded ahead of the host clock")
        burstAudio.submit(pcm, samplesPerChannel: 480, channels: 2, rate: 48_000,
                          at: CMTime(value: 201, timescale: 1))
        require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(burstSamples.last!), CMTime(value: 201, timescale: 1)) == 0,
                "audio failed to resume on the current host clock after a burst")
        // A format change also preserves the last delivered buffer's end.
        burstAudio.submit(Data(repeating: 0, count: 441 * 2), samplesPerChannel: 441, channels: 1, rate: 44_100,
                          at: CMTime(value: 2_010_001, timescale: 10_000))
        require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(burstSamples.last!), CMTime(value: 20_101, timescale: 100)) >= 0,
                "audio format change overlapped the previous format's last sample")
        let beforeStalePacket = burstSamples.count
        burstAudio.submit(pcm, samplesPerChannel: 480, channels: 2, rate: 48_000,
                          at: CMTime(value: 199, timescale: 1))
        require(burstSamples.count == beforeStalePacket, "stale packet moved a live timeline backwards")
        burstAudio.reset()
        burstAudio.submit(pcm, samplesPerChannel: 480, channels: 2, rate: 48_000,
                          at: CMTime(value: 199, timescale: 1))
        require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(burstSamples.last!), CMTime(value: 199, timescale: 1)) == 0,
                "explicit reset did not permit a fresh audio epoch")
        burstAudio.reset()
        print("media checks passed")
    }
}
