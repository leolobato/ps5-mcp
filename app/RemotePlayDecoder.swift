import CoreImage
import Foundation
import VideoToolbox

/// One complete Annex B H.264 access unit per submit, on the source's serial media queue.
/// Decoding and delivery finish before submit returns: there is no queue of obsolete frames,
/// and reset cannot be followed by a callback from a previous stream.
final class RemotePlayDecoder {
    private let onFrame: (CVPixelBuffer, CMTime) -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var configuredSPS: Data?
    private var configuredPPS: Data?
    private var needsIDR = true
    private var outputPool: CVPixelBufferPool?

    init(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) { self.onFrame = onFrame }

    deinit { reset() }

    func reset() {
        invalidateSession()
        sps = nil
        pps = nil
        outputPool = nil
    }

    private func invalidateSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        configuredSPS = nil
        configuredPPS = nil
        needsIDR = true
    }

    /// False asks the bridge for a new IDR after malformed data or a decoder failure.
    @discardableResult
    func submit(_ data: Data, at time: CMTime) -> Bool {
        guard time.isNumeric, data.count <= 16 * 1024 * 1024,
              let units = Self.nalUnits(data), !units.isEmpty else {
            needsIDR = true
            return false
        }
        var nextSPS = sps, nextPPS = pps
        var hasPicture = false, isIDR = false
        for unit in units {
            let type = unit[unit.startIndex] & 0x1f
            guard unit[unit.startIndex] & 0x80 == 0, type > 0, type < 24 else {
                needsIDR = true
                return false
            }
            switch type {
            case 7:
                guard unit.count >= 4 else { needsIDR = true; return false }
                nextSPS = unit
            case 8:
                guard unit.count >= 2 else { needsIDR = true; return false }
                nextPPS = unit
            case 1, 5:
                guard unit.count >= 2 else { needsIDR = true; return false }
                hasPicture = true
                isIDR = isIDR || type == 5
            case 2...4: // Data partitioned slices are not part of the requested SDR H.264 profile.
                needsIDR = true
                return false
            default: break
            }
        }
        sps = nextSPS
        pps = nextPPS
        guard hasPicture else { return true }
        guard let sps, let pps else { needsIDR = true; return false }
        if sps != configuredSPS || pps != configuredPPS {
            invalidateSession()
            guard isIDR, configure(sps: sps, pps: pps) else { return false }
        }
        guard !needsIDR || isIDR, let session, let format else { return false }

        var avcc = Data()
        for unit in units where ![7, 8].contains(unit[unit.startIndex] & 0x1f) {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { needsIDR = true; return false }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { needsIDR = true; return false }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { needsIDR = true; return false }
        var delivered = false
        // Neither asynchronous decompression nor temporal reordering: output is complete on return.
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: nil) { [self] status, _, image, pts, _ in
            guard status == noErr, let image, let buffer = self.sinkBuffer(image) else { return }
            delivered = true
            self.onFrame(buffer, pts)
        }
        let success = status == noErr && delivered
        needsIDR = !success
        return success
    }

    private func configure(sps: Data, pps: Data) -> Bool {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                p.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: [sps.count, pps.count],
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return false }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0,
              dimensions.width <= 4096, dimensions.height <= 2160 else { return false }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session) == noErr else { return false }
        format = description
        configuredSPS = sps
        configuredPPS = pps
        if let session { VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        return true
    }

    private func sinkBuffer(_ decoded: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(decoded) == 1920, CVPixelBufferGetHeight(decoded) == 1080,
           CVPixelBufferGetPixelFormatType(decoded) == kCVPixelFormatType_32BGRA { return decoded }
        if outputPool == nil {
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 1080,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &outputPool) == kCVReturnSuccess else { return nil }
        }
        guard let outputPool else { return nil }
        var output: CVPixelBuffer?
        // A slow downstream owner cannot turn retained scaled buffers into unbounded allocation.
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, outputPool, limits, &output) == kCVReturnSuccess,
              let output else { return nil }
        let image = CIImage(cvPixelBuffer: decoded)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: 1920 / image.extent.width,
                                                             y: 1080 / image.extent.height))
        context.render(scaled, to: output, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    private static func nalUnits(_ data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        var starts: [(offset: Int, length: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append((i, 4)); i += 4; continue
                }
            }
            i += 1
        }
        guard let first = starts.first, bytes[..<first.offset].allSatisfy({ $0 == 0 }) else { return nil }
        var units: [Data] = []
        for (index, start) in starts.enumerated() {
            let begin = start.offset + start.length
            var end = index + 1 < starts.count ? starts[index + 1].offset : bytes.count
            while end > begin && bytes[end - 1] == 0 { end -= 1 } // Annex B trailing_zero_8bits
            guard end > begin else { return nil }
            units.append(Data(bytes[begin..<end]))
        }
        return units
    }
}
