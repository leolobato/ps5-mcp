// FrameMeterOverlay: the frame meter over the bottom of the video, in the style of a Digital Foundry graph.
//
// A separate layer, so it does not appear in recordings: those get a CSV of the same numbers instead.

import AppKit
import QuartzCore

final class FrameMeterOverlay {
    let layer = CALayer()
    private let number = CATextLayer()
    private let unit = CATextLayer()
    private let detail = CATextLayer()
    private let grid = CAShapeLayer()
    private let line = CAShapeLayer()
    private var gridLabels: [CATextLayer] = []
    private var laidOut = CGRect.null

    private static let seconds = 10.0
    /// Slower frames are clipped to the top of the graph.
    private static let rangeMs = 66.7
    private static let gridLinesMs = [16.7, 33.3, 50.0]
    private static let panelWidth: CGFloat = 150
    private static let primaryInk = NSColor.white.cgColor
    private static let secondaryInk = NSColor(white: 0.72, alpha: 1).cgColor

    init() {
        layer.backgroundColor = NSColor(white: 0, alpha: 0.68).cgColor
        layer.zPosition = 10  // a restarted capture adds its preview layer after this one
        layer.isHidden = true
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        for text in [number, unit, detail] { style(text) }
        number.font = NSFont.monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        number.fontSize = 44
        number.foregroundColor = Self.primaryInk
        number.alignmentMode = .left
        unit.fontSize = 13
        unit.string = "FPS"
        detail.fontSize = 12
        grid.strokeColor = NSColor(white: 1, alpha: 0.2).cgColor
        grid.lineWidth = 1
        grid.fillColor = nil
        line.strokeColor = NSColor(srgbRed: 0x1F / 255.0, green: 0xA3 / 255.0, blue: 0x5C / 255.0, alpha: 1).cgColor
        line.lineWidth = 2
        line.lineJoin = .round
        line.fillColor = nil
        layer.masksToBounds = true
        for child in [grid, line, number, unit, detail] as [CALayer] {
            child.actions = ["contents": NSNull(), "path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer.addSublayer(child)
        }
        gridLabels = Self.gridLinesMs.map { milliseconds in
            let label = CATextLayer()
            style(label)
            label.fontSize = 11
            label.string = String(format: "%.1f ms", milliseconds)
            layer.addSublayer(label)
            return label
        }
    }

    private func style(_ text: CATextLayer) {
        text.font = NSFont.systemFont(ofSize: 12)
        text.foregroundColor = Self.secondaryInk
        text.isWrapped = false
        text.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    /// `reading` nil means this source cannot be measured.
    func update(_ reading: FrameMeterReading?, in bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layOut(in: bounds, scale: scale)
        guard let reading else {
            number.string = "–"
            detail.string = "Not available on this source"
            line.path = nil
            return
        }
        number.string = reading.fps.map { String(format: "%.0f", $0) } ?? "–"
        detail.string = Self.detail(reading)
        line.path = path(reading)
    }

    private static func detail(_ reading: FrameMeterReading) -> String {
        switch reading.state {
        case .starting: return "Starting"
        case .stillPicture: return "Static"
        case .noSignal: return "No signal"
        case .measuring:
            return reading.lowOnePercentFps.map { String(format: "1%% low %.0f", $0) } ?? "1% low –"
        }
    }

    private var plot: CGRect {
        let frame = layer.bounds.insetBy(dx: 0, dy: 10)
        return CGRect(x: Self.panelWidth, y: frame.minY, width: max(0, frame.width - Self.panelWidth - 12), height: frame.height)
    }

    private func layOut(in bounds: CGRect, scale: CGFloat) {
        let height = max(96, (bounds.height * 0.2).rounded())
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        guard frame != laidOut || layer.contentsScale != scale else { return }
        laidOut = frame
        layer.frame = frame
        layer.contentsScale = scale
        for text in [number, unit, detail] + gridLabels { text.contentsScale = scale }
        number.frame = CGRect(x: 14, y: height / 2 - 18, width: 84, height: 54)
        unit.frame = CGRect(x: 98, y: height / 2 - 6, width: 40, height: 18)
        detail.frame = CGRect(x: 14, y: height / 2 - 40, width: Self.panelWidth - 18, height: 18)
        grid.frame = layer.bounds
        line.frame = layer.bounds
        let plot = plot
        let lines = CGMutablePath()
        for (index, milliseconds) in Self.gridLinesMs.enumerated() {
            let y = plot.minY + CGFloat(milliseconds / Self.rangeMs) * plot.height
            lines.move(to: CGPoint(x: plot.minX, y: y))
            lines.addLine(to: CGPoint(x: plot.maxX, y: y))
            gridLabels[index].frame = CGRect(x: plot.maxX - 52, y: y + 1, width: 52, height: 15)
        }
        grid.path = lines
    }

    /// A step line: each frame's time is held for as long as that frame was on screen. Lost frames leave a break.
    private func path(_ reading: FrameMeterReading) -> CGPath? {
        guard reading.state != .noSignal else { return nil }
        let plot = plot
        guard plot.width > 0, plot.height > 0 else { return nil }
        let path = CGMutablePath()
        let x = { (time: Double) in plot.maxX - CGFloat((reading.now - time) / Self.seconds) * plot.width }
        var previous: Double?
        for sample in reading.samples {
            let begin = sample.time - sample.milliseconds / 1000
            let y = plot.minY + CGFloat(min(sample.milliseconds, Self.rangeMs) / Self.rangeMs) * plot.height
            let left = max(plot.minX, x(begin))
            if let previous, abs(previous - begin) < reading.refreshMs / 2000 {
                path.addLine(to: CGPoint(x: left, y: y))
            } else {
                path.move(to: CGPoint(x: left, y: y))
            }
            path.addLine(to: CGPoint(x: x(sample.time), y: y))
            previous = sample.time
        }
        return path
    }
}
