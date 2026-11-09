import AppKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

/// Red, green, blue at a point measured from the image's top left.
func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    let color = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
}

@main
struct Tests {
    static func main() throws {
        let width = 1920, height = 1080
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let frame = context.makeImage()!

        // 33.3 ms frames over the graph's last 5 seconds.
        let samples = (0..<150).map { FrameMeterSample(time: 95 + Double($0) / 30, milliseconds: 1000.0 / 30) }
        let reading = FrameMeterReading(state: .measuring, fps: 30, lowOnePercentFps: 29, gaps: 0, refreshMs: 1000.0 / 60,
                                        samples: samples, now: 100)
        let image = FrameMeterOverlay.composite(reading, over: frame, viewWidth: 960)!
        require(image.width == width && image.height == height, "the snapshot keeps the frame's size")

        let picture = pixel(image, x: 960, y: 200)
        require(picture.r > 250 && picture.g > 250 && picture.b > 250, "the picture above the meter is unchanged, got \(picture)")
        let panel = pixel(image, x: 960, y: 900)
        require(panel.r < 120, "the panel darkens the bottom of the picture, got \(panel)")

        // On screen the 33.3 ms line is half way up the plot. A flipped drawing would put it elsewhere only if not centered,
        // so the panel's own position above checks the direction, and this checks the line.
        var green = 0
        var rows = Set<Int>()
        let bitmap = NSBitmapImageRep(cgImage: image)
        for x in stride(from: 1200, to: 1800, by: 20) {
            for y in 860..<1080 {
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                if color.greenComponent > 0.5, color.redComponent < 0.3 { green += 1; rows.insert(y) }
            }
        }
        require(green > 0, "the frame time line is drawn")
        require(rows.allSatisfy { abs($0 - 972) < 12 }, "the 33.3 ms line is half way up the meter, got rows \(rows.sorted())")

        // The number and the 1% low are drawn in the left panel.
        var ink = 0
        for x in stride(from: 20, to: 280, by: 2) {
            for y in stride(from: 880, to: 1060, by: 2) where bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent > 0.6 { ink += 1 }
        }
        require(ink > 20, "the frame rate text is drawn, got \(ink)")

        // A source that cannot be measured still draws the panel, with no line.
        let unsupported = FrameMeterOverlay.composite(nil, over: frame, viewWidth: 960)!
        require(pixel(unsupported, x: 1500, y: 972).g < 200, "no line without a reading")
        require(FrameMeterOverlay.composite(reading, over: frame, viewWidth: 0) == nil, "a zero width cannot be drawn")

        if CommandLine.arguments.count > 1 {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("frame meter overlay checks passed")
    }
}
