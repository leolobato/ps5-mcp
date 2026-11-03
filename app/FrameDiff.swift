// FrameDiff: how much each captured frame differs from the one before it.
//
// The capture card always delivers 60 frames per second, so the game's own frame rate can be seen only by comparing
// pixels. The card sends Motion JPEG, so repeated game frames do not decode identically: the result is a measured
// difference, not a yes or no. Blocks keep a small moving object visible, which a whole-frame average would hide.

import CoreVideo
import Foundation

struct FrameDifference {
    /// All differences are in 8-bit luma steps per thumbnail cell.
    let mean: Double
    let largestBlock: Double
    /// The mean of each block row, top to bottom. An unchanged band among changed rows shows tearing.
    let rows: [Double]
}

/// Not thread-safe: use one instance from the frame queue.
final class FrameDiffer {
    static let width = 240, height = 135, blockSize = 15
    static let columns = width / blockSize, blockRows = height / blockSize
    private var current = [UInt8](repeating: 0, count: width * height)
    private var previous = [UInt8](repeating: 0, count: width * height)
    private var hasPrevious = false

    /// Forget the previous frame, as after a break in the signal.
    func reset() { hasPrevious = false }

    /// The difference from the previous frame. Nil for the first frame and for anything but BGRA.
    func compare(_ buffer: CVPixelBuffer) -> FrameDifference? {
        guard thumbnail(buffer) else { return nil }
        defer {
            swap(&current, &previous)
            hasPrevious = true
        }
        guard hasPrevious else { return nil }
        return difference()
    }

    /// Averages a grid of samples in each cell. Averaging removes most compression noise, and a grid keeps it cheap.
    private func thumbnail(_ buffer: CVPixelBuffer) -> Bool {
        let sourceWidth = CVPixelBufferGetWidth(buffer), sourceHeight = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              sourceWidth >= Self.width, sourceHeight >= Self.height else { return false }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let cellWidth = sourceWidth / Self.width, cellHeight = sourceHeight / Self.height
        let stepX = max(1, cellWidth / 4), stepY = max(1, cellHeight / 4)
        let samples = ((cellWidth + stepX - 1) / stepX) * ((cellHeight + stepY - 1) / stepY)
        current.withUnsafeMutableBufferPointer { out in
            for cellY in 0..<Self.height {
                let top = cellY * sourceHeight / Self.height
                for cellX in 0..<Self.width {
                    let left = cellX * sourceWidth / Self.width
                    var total = 0
                    var y = top
                    while y < top + cellHeight {
                        var pixel = bytes + y * stride + left * 4
                        var x = 0
                        while x < cellWidth {
                            total += Int(pixel[0]) + 2 * Int(pixel[1]) + Int(pixel[2])
                            pixel += stepX * 4
                            x += stepX
                        }
                        y += stepY
                    }
                    out[cellY * Self.width + cellX] = UInt8(total / (samples * 4))
                }
            }
        }
        return true
    }

    private func difference() -> FrameDifference {
        var blocks = [Int](repeating: 0, count: Self.columns * Self.blockRows)
        current.withUnsafeBufferPointer { now in
            previous.withUnsafeBufferPointer { before in
                for y in 0..<Self.height {
                    let blockY = y / Self.blockSize
                    for x in 0..<Self.width {
                        blocks[blockY * Self.columns + x / Self.blockSize] +=
                            abs(Int(now[y * Self.width + x]) - Int(before[y * Self.width + x]))
                    }
                }
            }
        }
        let cells = Double(Self.blockSize * Self.blockSize)
        var rows = [Double](repeating: 0, count: Self.blockRows)
        for row in 0..<Self.blockRows {
            let total = blocks[(row * Self.columns)..<((row + 1) * Self.columns)].reduce(0, +)
            rows[row] = Double(total) / (cells * Double(Self.columns))
        }
        return FrameDifference(mean: Double(blocks.reduce(0, +)) / (cells * Double(blocks.count)),
                               largestBlock: Double(blocks.max() ?? 0) / cells, rows: rows)
    }
}

/// A CSV of every frame and drop, for calibrating the meter. Rows are written on their own queue, so that the disk
/// cannot delay the frame queue.
final class FrameDiffLog {
    private let queue = DispatchQueue(label: "frame-diff-log", qos: .utility)
    private let file: FileHandle

    init?(path: String) {
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let file = FileHandle(forWritingAtPath: path) else { return nil }
        self.file = file
        let rows = (0..<FrameDiffer.blockRows).map { "row\($0)" }.joined(separator: ",")
        write("wall_s,kind,pts_s,mean,largest_block,compare_us,snapshot_us,reason,\(rows)\n")
    }

    func frame(pts: Double, difference: FrameDifference?, compareMicros: Int, snapshotMicros: Int?) {
        let wall = Date().timeIntervalSince1970
        let measured = difference.map { String(format: "%.3f,%.3f", $0.mean, $0.largestBlock) } ?? ","
        let rows = difference?.rows.map { String(format: "%.3f", $0) }.joined(separator: ",")
            ?? String(repeating: ",", count: FrameDiffer.blockRows - 1)
        let snapshot = snapshotMicros.map(String.init) ?? ""
        write(String(format: "%.6f,frame,%.6f,", wall, pts) + "\(measured),\(compareMicros),\(snapshot),,\(rows)\n")
    }

    func drop(pts: Double, reason: String) {
        let wall = Date().timeIntervalSince1970
        let empty = String(repeating: ",", count: FrameDiffer.blockRows - 1)
        write(String(format: "%.6f,drop,%.6f,", wall, pts) + ",,,,\(reason),\(empty)\n")
    }

    private func write(_ line: String) {
        queue.async { [file] in try? file.write(contentsOf: Data(line.utf8)) }
    }
}
