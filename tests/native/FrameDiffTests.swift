import CoreVideo
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

/// A gray BGRA frame. `paint` may change pixels; `padding` makes the rows wider than the picture.
func frame(width: Int = 1920, height: Int = 1080, padding: Int = 0, gray: UInt8 = 80,
           paint: ((Int, Int) -> UInt8?)? = nil) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = padding > 0 ? [kCVPixelBufferExtendedPixelsRightKey as String: padding] : [:]
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    precondition(status == kCVReturnSuccess)
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    // Bright padding must never reach the result.
    memset(bytes, 255, stride * height)
    for y in 0..<height {
        for x in 0..<width {
            let value = paint?(x, y) ?? gray
            let pixel = bytes + y * stride + x * 4
            pixel[0] = value; pixel[1] = value; pixel[2] = value; pixel[3] = 255
        }
    }
    return pixels
}

@main struct FrameDiffTests {
    static func main() {
        let differ = FrameDiffer()
        let plain = frame()
        require(differ.compare(plain) == nil, "the first frame has nothing to compare with")
        let same = differ.compare(plain)!
        require(same.mean == 0 && same.largestBlock == 0, "an identical frame differs by zero")

        // One 120x120 square: invisible in a whole-frame mean, obvious in its block.
        let small = frame { x, y in x < 120 && y < 120 ? 240 : nil }
        let changed = differ.compare(small)!
        require(changed.largestBlock > 100, "a small change fills its block, got \(changed.largestBlock)")
        require(changed.mean < 2, "a small change stays small in the mean, got \(changed.mean)")
        require(changed.rows[0] > 0 && changed.rows[8] == 0, "only the changed block row reports a difference")

        // Light noise averages down far below a real change.
        var seed: UInt64 = 42
        let noisy = frame { _, _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(76 + Int(seed >> 61))  // 76...83, around the gray of 80
        }
        differ.reset()
        require(differ.compare(plain) == nil, "reset forgets the previous frame")
        let noise = differ.compare(noisy)!
        require(noise.largestBlock < 3, "averaging reduces noise, got \(noise.largestBlock)")

        // The lower half changes: the top block rows report no difference, as a tear would.
        differ.reset()
        _ = differ.compare(plain)
        let halves = differ.compare(frame { _, y in y >= 600 ? 200 : nil })!
        require(halves.rows[0] == 0 && halves.rows[3] == 0 && halves.rows[8] > 100, "rows locate the changed band")

        // Padded rows give the same answer as packed ones.
        let padded = FrameDiffer()
        _ = padded.compare(frame(padding: 64))
        let wide = padded.compare(frame(padding: 64) { x, y in x < 120 && y < 120 ? 240 : nil })!
        require(CVPixelBufferGetBytesPerRow(frame(padding: 64)) > 1920 * 4, "the fixture has wide rows")
        require(wide.largestBlock == changed.largestBlock, "row padding does not change the result")

        // Only BGRA can be read.
        var other: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &other)
        require(FrameDiffer().compare(other!) == nil, "other formats are refused")

        let started = DispatchTime.now().uptimeNanoseconds
        let timed = FrameDiffer()
        for index in 0..<120 { _ = timed.compare(index % 2 == 0 ? plain : small) }
        let micros = (DispatchTime.now().uptimeNanoseconds - started) / 120_000
        print("frame diff checks passed; \(micros) us per frame")
    }
}
