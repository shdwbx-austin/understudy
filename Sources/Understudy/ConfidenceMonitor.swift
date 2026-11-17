@preconcurrency import AVFoundation
import CoreImage
import Foundation
import os
import UnderstudyCore

/// Pictures of the decks from a capture device: usually one quad-split multiviewer feed, cut into
/// a quarter per deck. Frames are analysed about five times a second at low resolution, so the
/// timing loop is never starved. Works with any capture device macOS sees as a camera (UVC).
@MainActor
final class ConfidenceMonitor: ObservableObject {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct Feed {
        var image: CGImage?
        var state: PictureState
    }

    /// By deck id.
    @Published private(set) var feeds: [Int: Feed] = [:]
    @Published private(set) var devices: [Device] = []
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    @Published private(set) var deviceName: String?

    private let capture: Capture
    private let processor = FrameProcessor()
    private var currentDeviceID: String?

    init() {
        capture = Capture(processor: processor)
        refreshDevices()
        capture.deliver = { [weak self] feeds in
            DispatchQueue.main.async { [self] in MainActor.assumeIsolated { self?.receive(feeds) } }
        }
    }

    func refreshDevices() {
        devices = Self.discovery().devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Capture devices macOS lists as cameras (shared with the Understudy recorder).
    nonisolated static func discovery() -> AVCaptureDevice.DiscoverySession {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
    }

    // MARK: Configuration

    /// Which part of the image is which deck, and how pictures are judged.
    func configure(layout: ConfidenceLayout, quadrants: [Int], singleDeck: Int, check: PictureCheckSettings) {
        var regions: [Int: CGRect] = [:]
        switch layout {
        case .quad:
            for (deck, quadrant) in quadrants.enumerated() where (0..<4).contains(quadrant) {
                let r = ConfidenceLayout.rect(quadrant: quadrant)
                regions[deck] = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
            }
        case .single:
            regions[singleDeck] = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        processor.configure(regions: regions, check: check)
        feeds = feeds.filter { regions[$0.key] != nil }
    }

    // MARK: Running

    func start(deviceID: String?) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    if granted { self?.start(deviceID: deviceID) } else { self?.error = "Camera access was declined." }
                }
            }
            return
        default:
            error = "Capture is blocked. Allow Understudy in System Settings › Privacy & Security › Camera."
            return
        }

        refreshDevices()
        let candidates = Self.discovery().devices
        guard let device = candidates.first(where: { $0.uniqueID == deviceID }) ?? (deviceID == nil ? candidates.first : nil) else {
            stop()
            error = deviceID == nil ? "No capture device found." : "The chosen capture device isn't connected."
            return
        }
        if isRunning, currentDeviceID == device.uniqueID { return }

        if let problem = capture.use(device) {
            error = "Couldn't open \(device.localizedName): \(problem)"
            return
        }
        processor.reset()
        currentDeviceID = device.uniqueID
        deviceName = device.localizedName
        error = nil
        isRunning = true
        capture.run()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        currentDeviceID = nil
        deviceName = nil
        feeds = [:]
        capture.halt()
    }

    private func receive(_ new: [Int: Feed]) {
        guard isRunning else { return }
        for (deck, feed) in new { feeds[deck] = feed }
    }

    /// Marks feeds as lost when frames stop arriving.
    func checkStale(now: Double) {
        guard isRunning else { return }
        let states = processor.states(at: now)
        for (deck, state) in states where feeds[deck]?.state != state {
            feeds[deck] = Feed(image: state == .noFeed ? nil : feeds[deck]?.image, state: state)
        }
    }

    /// Runs one frame through the same processing as captured video (used for testing).
    func inject(_ pixelBuffer: CVPixelBuffer, at time: Double) {
        isRunning = true
        receive(processor.process(pixelBuffer, at: time, force: true))
    }
}

// MARK: - Capture session (own queue)

/// Owns the AVCaptureSession. Configuration happens on the main thread before running;
/// starting, stopping and frame delivery happen on its serial queue.
private final class Capture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "understudy.confidence", qos: .utility)
    private let processor: FrameProcessor
    /// Set once, before running.
    var deliver: (@Sendable ([Int: ConfidenceMonitor.Feed]) -> Void)?

    init(processor: FrameProcessor) {
        self.processor = processor
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Switches the session to `device`; returns a problem, or nil.
    func use(_ device: AVCaptureDevice) -> String? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach { session.removeInput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return "it can't be used for capture." }
            session.addInput(input)
        } catch {
            return error.localizedDescription
        }
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        return nil
    }

    func run() { queue.async { [self] in if !session.isRunning { session.startRunning() } } }
    func halt() { queue.async { [self] in session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let feeds = processor.process(buffer, at: HostClock.now(), force: false)
        if !feeds.isEmpty { deliver?(feeds) }
    }
}

// MARK: - Frame processing (capture queue)

/// Crops each deck's region, makes a thumbnail and a 32×18 brightness grid, and runs the picture
/// checks. Called on the capture queue; configuration comes from the main thread under a lock.
final class FrameProcessor: @unchecked Sendable {
    private struct Config {
        var regions: [Int: CGRect] = [:]
        var check = PictureCheckSettings()
        var checkers: [Int: PictureChecker] = [:]
        var lastProcessed = -Double.infinity
    }

    private let state = OSAllocatedUnfairLock(initialState: Config())
    private let context = CIContext(options: [.cacheIntermediates: false])
    private static let interval = 0.2
    private static let thumbWidth: CGFloat = 384
    private static let gridSize = (w: 32, h: 18)
    /// Share of each side left out of the picture checks (labels sit along the bottom).
    private static let margin = (side: 0.08, top: 0.08, bottom: 0.18)

    func configure(regions: [Int: CGRect], check: PictureCheckSettings) {
        state.withLock {
            $0.regions = regions
            $0.check = check
            $0.checkers = $0.checkers.filter { regions[$0.key] != nil }
            for key in $0.checkers.keys { $0.checkers[key]?.settings = check }
        }
    }

    func reset() {
        state.withLock { $0.checkers = [:]; $0.lastProcessed = -.infinity }
    }

    func states(at time: Double) -> [Int: PictureState] {
        state.withLock { s in
            Dictionary(uniqueKeysWithValues: s.regions.keys.map { ($0, s.checkers[$0]?.state(at: time) ?? .noFeed) })
        }
    }

    func process(_ buffer: CVPixelBuffer, at time: Double, force: Bool) -> [Int: ConfidenceMonitor.Feed] {
        let regions: [Int: CGRect]? = state.withLock { s in
            guard force || time - s.lastProcessed >= Self.interval else { return nil }
            s.lastProcessed = time
            return s.regions
        }
        guard let regions else { return [:] }

        let image = CIImage(cvPixelBuffer: buffer)
        let full = image.extent
        var out: [Int: ConfidenceMonitor.Feed] = [:]
        for (deck, r) in regions {
            // Normalised rect has its origin top left; Core Image's is bottom left.
            let crop = CGRect(
                x: full.minX + r.minX * full.width,
                y: full.minY + (1 - r.maxY) * full.height,
                width: r.width * full.width,
                height: r.height * full.height
            ).integral
            let region = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            let scale = Self.thumbWidth / max(1, crop.width)
            let thumb = region.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let cg = context.createCGImage(thumb, from: thumb.extent.integral)
            // Judge the picture away from the quadrant's edges and bottom, where multiviewers draw
            // borders, tallies and source labels (and where a neighbouring quadrant can bleed in).
            let inset = CGRect(
                x: crop.width * Self.margin.side, y: crop.height * Self.margin.bottom,
                width: crop.width * (1 - 2 * Self.margin.side),
                height: crop.height * (1 - Self.margin.bottom - Self.margin.top)
            ).integral
            let analysed = region.cropped(to: inset).transformed(by: CGAffineTransform(translationX: -inset.minX, y: -inset.minY))
            let grid = lumaGrid(analysed, size: inset.size)
            let pictureState = state.withLock { s -> PictureState in
                var checker = s.checkers[deck] ?? PictureChecker(settings: s.check)
                let result = grid.map { checker.update($0, at: time) } ?? checker.state(at: time)
                s.checkers[deck] = checker
                return result
            }
            out[deck] = ConfidenceMonitor.Feed(image: cg, state: pictureState)
        }
        return out
    }

    /// A 32×18 grid of brightness (Rec. 709 luma) for `region`.
    private func lumaGrid(_ region: CIImage, size: CGSize) -> LumaGrid? {
        let (w, h) = Self.gridSize
        guard size.width > 0, size.height > 0 else { return nil }
        let small = region.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / size.width, y: CGFloat(h) / size.height))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &bytes, rowBytes: w * 4,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var values = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(bytes[i * 4]), g = Float(bytes[i * 4 + 1]), b = Float(bytes[i * 4 + 2])
            values[i] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }
        return LumaGrid(width: w, height: h, values: values)
    }
}
