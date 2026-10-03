// Frames: the capture card (AVFoundation), or a camera-free source for development and tests.
//
// - camera:     AVCaptureSession; the window draws it with AVCaptureVideoPreviewLayer, audio plays directly.
// - file:PATH   the image at PATH (re-read when it changes), scaled to 1920x1080, fed at 30 fps.
// - synthetic   a moving bar on gray, 1920x1080 at 30 fps.
// Every frame goes to FrameSink: newest frame, <state>/latest.jpg at the snapshot rate, change detection.

import AVFoundation
import CoreImage
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

let frameWidth = 1920, frameHeight = 1080

func say(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

/// Receives every frame; keeps the newest, writes snapshots, detects changes for latency measurements.
final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var lastWrite = 0.0
    private let path: String
    private let interval: Double
    private(set) var frames: UInt64 = 0
    private(set) var lastFrameAt = 0.0

    // Change detection: a 32x18 luma thumbnail per frame, compared with an armed reference.
    private var reference: [UInt8]?
    private var watchThreshold = 0.0
    private var watchCallback: ((Double, Double) -> Void)?

    init(path: String, fps: Double) {
        self.path = path
        self.interval = fps > 0 ? 1.0 / fps : .infinity
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        push(buffer)
    }

    func push(_ buffer: CVPixelBuffer) {
        let now = uptimeSeconds()
        lock.lock()
        latest = buffer
        frames += 1
        lastFrameAt = now
        let callback = watchCallback
        lock.unlock()
        if callback != nil { checkChange(buffer, at: now) }
        if now - lastWrite >= interval {
            lastWrite = now
            write(buffer)
        }
    }

    func latestBuffer() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func latestImage() -> CGImage? {
        guard let buffer = latestBuffer() else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return ci.createCGImage(image, from: image.extent)
    }

    var frameAge: Double { lastFrameAt > 0 ? uptimeSeconds() - lastFrameAt : -1 }

    @discardableResult
    func writeNow() -> Bool {
        guard let buffer = latestBuffer() else { return false }
        return write(buffer)
    }

    @discardableResult
    private func write(_ buffer: CVPixelBuffer) -> Bool {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = ci.createCGImage(image, from: image.extent) else { return false }
        let tmp = path + ".\(UUID().uuidString).tmp"  // the frame queue and the control socket may write at once
        let url = URL(fileURLWithPath: tmp) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return false }
        return rename(tmp, path) == 0
    }

    private func luma(_ buffer: CVPixelBuffer) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32 * 18)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return out }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for ty in 0..<18 {
            for tx in 0..<32 {
                let x = (tx * width / 32 + width / 64), y = (ty * height / 18 + height / 36)
                let p = bytes + y * stride + x * 4  // BGRA
                out[ty * 32 + tx] = UInt8((Int(p[0]) + Int(p[1]) * 2 + Int(p[2])) / 4)
            }
        }
        return out
    }

    private func checkChange(_ buffer: CVPixelBuffer, at now: Double) {
        let current = luma(buffer)
        lock.lock()
        defer { lock.unlock() }
        guard let callback = watchCallback else { return }
        guard let reference else {
            self.reference = current
            return
        }
        var total = 0
        for i in 0..<current.count { total += abs(Int(current[i]) - Int(reference[i])) }
        let diff = Double(total) / Double(current.count)
        if diff >= watchThreshold {
            watchCallback = nil
            self.reference = nil
            callback(now, diff)
        }
    }

    /// The next frame becomes the reference; `callback` fires on the first frame that differs by `threshold`.
    func watch(threshold: Double, callback: @escaping (Double, Double) -> Void) {
        lock.lock()
        reference = nil
        watchThreshold = threshold
        watchCallback = callback
        lock.unlock()
    }

    func cancelWatch() {
        lock.lock()
        watchCallback = nil
        reference = nil
        lock.unlock()
    }
}

// MARK: - sources

protocol FrameSource: AnyObject {
    var name: String { get }
    func start()
    func stop()
    func setMuted(_ muted: Bool)
}

/// The capture card. Camera and microphone permission belong to this app bundle.
final class CameraSource: FrameSource {
    let session = AVCaptureSession()
    let name: String
    private let queue = DispatchQueue(label: "frames", qos: .userInteractive)
    private let audioPreview = AVCaptureAudioPreviewOutput()

    init(video: String, audio: String?, sink: FrameSink) throws {
        name = "camera:\(video)"
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera], mediaType: nil, position: .unspecified)
        guard let device = discovery.devices.first(where: { $0.localizedName == video && $0.hasMediaType(.video) })
        else {
            throw NSError(domain: "ps5-app", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "video device '\(video)' not found"])
        }
        session.beginConfiguration()
        session.addInput(try AVCaptureDeviceInput(device: device))
        // Setting the format after adding the input keeps the card's native 1080p60 (the session yields to it).
        if let best = device.formats.max(by: { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }) {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(sink, queue: queue)
        session.addOutput(output)

        if let audio {
            let audioDiscovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            if let mic = audioDiscovery.devices.first(where: { $0.localizedName == audio }) {
                session.addInput(try AVCaptureDeviceInput(device: mic))
                audioPreview.volume = 1.0
                session.addOutput(audioPreview)
            } else {
                say("audio device '\(audio)' not found; continuing without audio")
            }
        }
        session.commitConfiguration()
    }

    /// Asks for camera/microphone permission first (the prompt belongs to this app), then starts the session.
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if !granted { say("camera permission denied: System Settings > Privacy & Security > Camera > PS5") }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                if granted { self.queue.async { self.session.startRunning() } }
            }
        }
    }
    func stop() { session.stopRunning() }
    func setMuted(_ muted: Bool) { audioPreview.volume = muted ? 0 : 1 }
}

func makeBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
    CVPixelBufferCreate(nil, frameWidth, frameHeight, kCVPixelFormatType_32BGRA, attrs, &buffer)
    return buffer!
}

/// Draws a CGImage into a 1920x1080 BGRA buffer (scaled to fill, as assign.py resizes frames).
func render(_ image: CGImage) -> CVPixelBuffer {
    let buffer = makeBuffer()
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: frameWidth, height: frameHeight,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    return buffer
}

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Timer-driven sources share this loop.
class TimedSource: FrameSource {
    let name: String
    let sink: FrameSink
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "frames", qos: .userInteractive)

    init(name: String, sink: FrameSink) {
        self.name = name
        self.sink = sink
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30)
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = self.nextFrame() else { return }
            self.sink.push(buffer)
        }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel() }
    func setMuted(_ muted: Bool) {}
    func nextFrame() -> CVPixelBuffer? { nil }
}

/// The image at `path`, re-read whenever its modification time or size changes. Replace it atomically.
final class FileSource: TimedSource {
    private let path: String
    private var stamp: (Int, Int, Int) = (-1, -1, -1)
    private var buffer: CVPixelBuffer?

    init(path: String, sink: FrameSink) {
        self.path = path
        super.init(name: "file:\(path)", sink: sink)
    }

    override func nextFrame() -> CVPixelBuffer? {
        var info = stat()
        if stat(path, &info) == 0 {
            let now = (info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, Int(info.st_size))
            if now != stamp, let image = loadImage(path) {
                stamp = now
                buffer = render(image)
            }
        }
        return buffer
    }
}

/// A white bar sweeping across gray: frames always change, for watch_change and the window.
final class SyntheticSource: TimedSource {
    private var tick = 0
    private let buffers = [makeBuffer(), makeBuffer(), makeBuffer()]

    init(sink: FrameSink) { super.init(name: "synthetic", sink: sink) }

    override func nextFrame() -> CVPixelBuffer? {
        tick += 1
        let buffer = buffers[tick % buffers.count]
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let barX = (tick * 24) % frameWidth
        var gray: UInt32 = 0xFF50_5050, white: UInt32 = 0xFFF0_F0F0  // BGRA, opaque
        for y in 0..<frameHeight {
            let row = base + y * stride
            memset_pattern4(row, &gray, frameWidth * 4)
            memset_pattern4(row + barX * 4, &white, min(160, frameWidth - barX) * 4)
        }
        return buffer
    }
}
