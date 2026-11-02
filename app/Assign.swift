// Answer "Who's using this controller?" for a fresh virtual pad (src/ps5mcp/assign.py).
//
// Only the virtual pad can answer the screen it caused, and until it does the PS5 ignores its input. After every
// (re)connect the app looks for the dialog title and presses Cross through the pad, which picks the focused,
// logged-in user. It never presses blindly: no dialog, no press.
//
// Side effect: the PS5 then turns the user's DualSense off. Pressing PS on
// the DualSense and picking the same user brings it back, and both controllers work.
//
// The focused profile need not be the pad's user, and Cross takes whoever is focused. So the app reads the names (Vision),
// which stay centered on the focus as the row scrolls, moves until the pad's user is focused, and presses Cross only then.
// For a name it cannot find, controller 1 answers the profile focused at first, and the others get no Cross.
//
// Matching mirrors assign.dialog_score: grayscale at quarter resolution, normalised cross-correlation, title at
// (712, 168) in a 1920x1080 frame, within 24 px. Python searches the whole frame and rejects a best match outside
// that window; this searches only the window, which gives the same answer whenever the title is on screen.

import CoreImage
import CoreVideo
import Foundation
import Vision

final class Assigner {
    static let dialogAt = (x: 712, y: 168)
    static let minScore = 0.9
    static let maxOffset = 24
    static let scale = 4

    private let tw: Int, th: Int
    private let template: [Double]  // mean-subtracted
    private let tNorm: Double

    init(templatePath: String) throws {
        guard let image = loadImage(templatePath) else { throw BadInput("cannot read \(templatePath)") }
        let gray = Assigner.quarterGray(Assigner.rgba(image), width: image.width, height: image.height)
        tw = image.width / Assigner.scale
        th = image.height / Assigner.scale
        let mean = gray.reduce(0, +) / Double(gray.count)
        template = gray.map { $0 - mean }
        tNorm = sqrt(template.reduce(0) { $0 + $1 * $1 })
    }

    /// BGRA bytes of `image`, at its own size.
    private static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// PIL "L" luma (ITU-R 601-2), then 4x4 box averages.
    private static func quarterGray(_ bgra: [UInt8], width: Int, height: Int) -> [Double] {
        let qw = width / scale, qh = height / scale
        var out = [Double](repeating: 0, count: qw * qh)
        bgra.withUnsafeBufferPointer { p in
            for qy in 0..<qh {
                for qx in 0..<qw {
                    out[qy * qw + qx] = cell(p.baseAddress!, stride: width * 4, x: qx * scale, y: qy * scale)
                }
            }
        }
        return out
    }

    private static func cell(_ base: UnsafePointer<UInt8>, stride: Int, x: Int, y: Int) -> Double {
        var sum = 0
        for dy in 0..<scale {
            var p = base + (y + dy) * stride + x * 4
            for _ in 0..<scale {
                sum += (Int(p[2]) * 19595 + Int(p[1]) * 38470 + Int(p[0]) * 7471 + 0x8000) >> 16
                p += 4
            }
        }
        return Double(sum) / Double(scale * scale)
    }

    /// Match score of the dialog title at its expected place (0 if the frame is missing or another size).
    func score(_ buffer: CVPixelBuffer) -> Double {
        var buffer = buffer
        if CVPixelBufferGetWidth(buffer) != frameWidth || CVPixelBufferGetHeight(buffer) != frameHeight {
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cg = CIContext().createCGImage(image, from: image.extent) else { return 0 }
            buffer = render(cg)
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let base = UnsafePointer(raw.assumingMemoryBound(to: UInt8.self))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let s = Assigner.scale, reach = Assigner.maxOffset / s
        let x0 = Assigner.dialogAt.x / s - reach, y0 = Assigner.dialogAt.y / s - reach
        let rw = tw + 2 * reach, rh = th + 2 * reach
        var region = [Double](repeating: 0, count: rw * rh)
        for ry in 0..<rh {
            for rx in 0..<rw {
                region[ry * rw + rx] = Assigner.cell(base, stride: stride, x: (x0 + rx) * s, y: (y0 + ry) * s)
            }
        }
        var best = -1.0
        let n = Double(tw * th)
        for oy in 0...(2 * reach) {
            for ox in 0...(2 * reach) {
                var corr = 0.0, sum = 0.0, sum2 = 0.0
                for ty in 0..<th {
                    let row = (oy + ty) * rw + ox
                    for tx in 0..<tw {
                        let f = region[row + tx]
                        corr += f * template[ty * tw + tx]
                        sum += f
                        sum2 += f * f
                    }
                }
                let variance = max(sum2 - sum * sum / n, 1e-9)
                best = max(best, corr / (sqrt(variance) * tNorm))
            }
        }
        return best
    }

    /// The profile names in the dialog, left to right ("Add User" left out): the text on the name row of the tiles.
    func users(_ buffer: CVPixelBuffer) -> [String] { profiles(buffer).map(\.name) }

    /// The same names with their centers, across the panel: 0 is its left edge and 1 its right. The row scrolls, and the
    /// focused profile is always at 0.5, so a name near an edge means more of the row may be out of sight.
    func profiles(_ buffer: CVPixelBuffer) -> [(name: String, x: Double)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // The name row of a 1920x1080 frame, inside the dialog panel; Vision's y goes up from the bottom.
        request.regionOfInterest = CGRect(x: 240.0 / 1920, y: 1 - 705.0 / 1080, width: 1440.0 / 1920, height: 70.0 / 1080)
        guard (try? VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .compactMap { o in o.topCandidates(1).first.map { (name: $0.string, x: Double(o.boundingBox.midX)) } }
            .filter { $0.name.caseInsensitiveCompare("Add User") != .orderedSame }
            .sorted { $0.x < $1.x }
    }

    /// The name of the focused profile, if the focus is on one (it can be on Add User).
    static func focused(_ profiles: [(name: String, x: Double)]) -> String? {
        profiles.first { abs($0.x - 0.5) < 0.1 }?.name
    }

    /// Characters video compression and text recognition mix up. Other differences are different names: User1 is not User2.
    private static let lookAlike: [Set<Character>] = [["i", "j", "l", "1", "|", "!"], ["o", "0"], ["s", "5"], ["z", "2"], ["b", "8"]]

    /// Where `target` is among the names read from the dialog; case does not count. `tolerant` also accepts a misread name:
    /// one look-alike character off, the only name that close, and not the name of anyone in `others`.
    static func userIndex(_ users: [String], target: String, tolerant: Bool, others: [String] = []) -> Int? {
        let wanted = Array(target.lowercased())
        if let exact = users.firstIndex(where: { Array($0.lowercased()) == wanted }) { return exact }
        guard tolerant else { return nil }
        let taken = Set(others.map { $0.lowercased() })
        let close = users.indices.filter { index in
            let name = Array(users[index].lowercased())
            guard name.count == wanted.count, !taken.contains(users[index].lowercased()) else { return false }
            let differing = name.indices.filter { name[$0] != wanted[$0] }
            return differing.count == 1 && lookAlike.contains { $0.contains(name[differing[0]]) && $0.contains(wanted[differing[0]]) }
        }
        return close.count == 1 ? close[0] : nil
    }

    /// Watch for the dialog for `timeout` s; when it shows, `answer` gets the frame and presses (or returns false to
    /// leave the dialog alone). Returns true if the dialog was answered.
    func assignIfAsked(frame: () -> CVPixelBuffer?, answer: (CVPixelBuffer) -> Bool, timeout: Double = 6,
                       interval: Double = 0.5, log: (String) -> Void) -> Bool {
        let deadline = uptimeSeconds() + timeout
        func current() -> Double? { frame().map(score) }
        while true {
            let buffer = frame()
            let found = buffer.map(score)
            if found == nil { log("auto-assign: no frame") }
            if let buffer, let found, found >= Assigner.minScore {
                log(String(format: "auto-assign: 'Who's using this controller?' visible (score %.3f)", found))
                guard answer(buffer) else { return false }
                Thread.sleep(forTimeInterval: 1.0)
                if (current() ?? 0) < Assigner.minScore {
                    log("auto-assign: done; turn the DualSense back on with its PS button if it went off")
                    return true
                }
                log("auto-assign: dialog still visible after Cross")
                return false
            }
            if uptimeSeconds() >= deadline { return false }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
