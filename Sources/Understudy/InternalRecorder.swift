@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os
import UnderstudyCore
import VideoToolbox

// The Understudy recorder's engine: one source (capture device, NDI or test pattern) feeding an
// AVAssetWriter, with a QuickTime timecode track stamped from show code at the start of each take.
// Everything runs on one serial queue; the main thread drives it through `InternalRecorder`'s
// methods and hears back through `onStatus` and `onTakeFinished`.

/// One frame from a recorder source.
struct RecorderFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    /// Source clock, seconds: places the frame on the recording's frame grid.
    let time: Double
    /// HostClock seconds when the frame was captured or arrived: what show code is compared at.
    let host: Double
    /// Rate the source says it runs at (0: not said; measured instead).
    let fps: Double
}

/// Something that delivers frames on the recorder's queue.
protocol RecorderFrameSource: AnyObject, Sendable {
    var name: String { get }
    /// Starts delivering frames to `deliver`, always called on `queue`. Returns a problem, or nil.
    func start(on queue: DispatchQueue, deliver: @escaping (RecorderFrame) -> Void,
               fail: @escaping @Sendable (String) -> Void) -> String?
    func stop()
}

// MARK: - Sources

/// A capture card, webcam or Continuity Camera through AVFoundation, at its own format and rate.
final class CaptureFrameSource: NSObject, RecorderFrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let name: String
    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let control = DispatchQueue(label: "understudy.recorder.capture", qos: .userInitiated)
    private var deliver: ((RecorderFrame) -> Void)?
    private var fps: Double = 0

    init(device: AVCaptureDevice) {
        self.device = device
        name = device.localizedName
    }

    /// The capture devices the confidence monitor offers too.
    static func devices() -> [AVCaptureDevice] { ConfidenceMonitor.discovery().devices }

    func start(on queue: DispatchQueue, deliver: @escaping (RecorderFrame) -> Void,
               fail: @escaping @Sendable (String) -> Void) -> String? {
        self.deliver = deliver
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                return "\(name) is in use or can't be captured from."
            }
            session.addInput(input)
            // Keep the device's own format (a capture card's input), not the session preset's:
            // setting the format directly takes the session off its preset.
            if (try? device.lockForConfiguration()) != nil {
                device.activeFormat = device.activeFormat
                device.unlockForConfiguration()
            }
        } catch {
            session.commitConfiguration()
            return error.localizedDescription
        }
        // 4:2:0 video range: what the hardware encoders take without converting.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return "\(name) can't deliver frames."
        }
        session.addOutput(output)
        session.commitConfiguration()
        let d = device.activeVideoMinFrameDuration
        fps = d.isValid && d.value > 0 ? Double(d.timescale) / Double(d.value) : 0
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            fail(error?.localizedDescription ?? "Capture stopped.")
        }
        control.async { [session] in session.startRunning() }
        return nil
    }

    func stop() {
        control.async { [session] in session.stopRunning() }
        NotificationCenter.default.removeObserver(self)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Capture timestamps are on the host clock, the same clock as HostClock.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let t = pts.isValid ? pts.seconds : HostClock.now()
        deliver?(RecorderFrame(buffer: buffer, time: t, host: t, fps: fps))
    }
}

/// An NDI source, received on its own thread.
final class NDIFrameSource: RecorderFrameSource, @unchecked Sendable {
    let name: String
    private let receiver: NDIReceiver

    init(sourceName: String) {
        name = sourceName
        receiver = NDIReceiver(sourceName: sourceName)
    }

    func start(on queue: DispatchQueue, deliver: @escaping (RecorderFrame) -> Void,
               fail: @escaping @Sendable (String) -> Void) -> String? {
        nonisolated(unsafe) let deliver = deliver
        receiver.onFrame = { frame in
            // Blocks the receive thread while the frame is written, so a busy encoder makes NDI
            // drop frames (counted as gaps) instead of frames piling up in memory.
            queue.sync {
                deliver(RecorderFrame(buffer: frame.buffer, time: frame.sourceTime ?? frame.arrived,
                                      host: frame.arrived, fps: frame.fps))
            }
        }
        receiver.onError = fail
        return receiver.start()
    }

    func stop() { receiver.stop() }
}

/// Colour bars with a running clock, made on this Mac: checks the encoder and disk with no hardware.
final class TestPatternFrameSource: RecorderFrameSource, @unchecked Sendable {
    let name = "Test pattern"
    let rate: FrameRate
    private let pattern: NDITestPattern
    private var timer: DispatchSourceTimer?

    init(rate: FrameRate = .fps29_97, title: String = "Understudy recorder") {
        self.rate = rate
        pattern = NDITestPattern(title: title, note: "Test pattern recorded on this Mac")
    }

    func start(on queue: DispatchQueue, deliver: @escaping (RecorderFrame) -> Void,
               fail: @escaping @Sendable (String) -> Void) -> String? {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1 / rate.exact
        let fps = rate.exact
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [pattern] in
            let now = HostClock.now()
            guard let buffer = pattern.frame() else { return }
            deliver(RecorderFrame(buffer: buffer, time: now, host: now, fps: fps))
        }
        self.timer = timer
        timer.resume()
        return nil
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - Recorder

enum RecorderError: Error, Sendable {
    case failed(String)

    var message: String {
        switch self { case .failed(let m): return m }
    }
}

final class InternalRecorder: @unchecked Sendable {
    struct Status: Equatable, Sendable {
        enum State: Equatable, Sendable { case closed, opening, open, failed(String) }
        var state: State = .closed
        var recording = false
        /// "1920×1080 29.97".
        var signal: String?
        /// HyperDeck-style name of the incoming format ("1080p2997"), nil with no signal.
        var videoFormat: String?
        /// The last format seen (kept through a signal loss).
        var lastVideoFormat: String?
        var health = RecorderHealth()
        /// Timecode of the newest frame recorded.
        var timecode: Timecode?
        var fileName: String?
        var sourceName: String?
    }

    /// Timecode of the newest recorded frame and the host time that frame was captured.
    struct Position: Sendable {
        var timecode: Timecode
        var host: Double
        var rate: FrameRate
    }

    /// What a new take needs.
    struct TakeRequest: Sendable {
        var url: URL
        var takeID: Int
        var codec: RecorderCodec
        /// Timecode-of-day seconds (show code, or the time of day without it) at host time `startHost`.
        var startSeconds: Double
        var startHost: Double
        /// Timecode at the video rate, or (50p/59.94p/60p) at its LTC rate.
        var timecodeAtVideoRate: Bool
        var dropFrame: Bool
    }

    let deckName: String
    private let queue: DispatchQueue
    private var source: RecorderFrameSource?
    private var sourceRef: RecorderSource?
    private var status = Status()
    private var dropFrame = false
    private var writer: TakeWriter?
    private var pending: TakeRequest?
    private var statusTimer: DispatchSourceTimer?
    private var lastFrameHost: Double?
    private var measuredFPS: Double?
    private var lastFrameTime: Double?
    /// Size and rate of the latest frame, so a take's file can open at REC rather than on its first frame.
    private var lastFrameInfo: (width: Int, height: Int, rate: FrameRate)?
    private var lastSize: (bytes: Int64, at: Double)?
    private var lastFreeCheck = -Double.infinity
    private var freeBytes: Int64?
    private var folder: URL?
    private var openGeneration = 0
    private let position = OSAllocatedUnfairLock<Position?>(initialState: nil)
    private let recordingFlag = OSAllocatedUnfairLock(initialState: false)

    /// Called on the recorder's queue whenever the status changes (and a few times a second).
    var onStatus: (@Sendable (Status) -> Void)?
    /// Called on the recorder's queue when a take's file is finished (or failed).
    var onTakeFinished: (@Sendable (Result<RecorderTake, RecorderError>) -> Void)?

    init(deckName: String) {
        self.deckName = deckName
        queue = DispatchQueue(label: "understudy.recorder.\(deckName)", qos: .userInteractive)
    }

    deinit {
        source?.stop()
        statusTimer?.cancel()
    }

    // MARK: Control (any thread)

    var isRecording: Bool { recordingFlag.withLock { $0 } }

    /// Timecode of the newest recorded frame, for logging show code against the take.
    func currentPosition() -> Position? { position.withLock { $0 } }

    /// Opens `source` (closing any other). `dropFrame`: count 29.97/59.94 drop-frame, as show code does.
    func open(_ ref: RecorderSource, dropFrame: Bool, folder: URL?) {
        queue.async { [self] in
            if sourceRef == ref, source != nil, status.state != .closed {
                self.dropFrame = dropFrame
                return
            }
            closeSource()
            self.dropFrame = dropFrame
            self.folder = folder
            sourceRef = ref
            status = Status()
            status.state = .opening
            status.sourceName = ref.label
            openGeneration += 1
            publish()
            let generation = openGeneration
            Self.makeSource(ref) { [weak self] made in
                guard let self else { return }
                self.queue.async { self.started(made, generation: generation) }
            }
        }
    }

    /// Stops the source (finishing any take first).
    func close() {
        queue.async { [self] in
            if writer != nil { finishTake() }
            closeSource()
            status = Status()
            publish()
        }
    }

    /// Where the next take's file will go (for "time left on disk").
    func setFolder(_ url: URL?) {
        queue.async { [self] in
            folder = url
            lastFreeCheck = -.infinity
        }
    }

    func setDropFrame(_ df: Bool) { queue.async { [self] in dropFrame = df } }

    /// Starts a take: the file opens on the next frame. Ignored while one is running.
    func startTake(_ request: TakeRequest) {
        queue.async { [self] in
            guard writer == nil, pending == nil else { return }
            pending = request
            recordingFlag.withLock { $0 = true }
            status.recording = true
            status.fileName = request.url.lastPathComponent
            status.health.droppedFrames = 0
            status.health.encoderDrops = 0
            status.health.skippedFrames = 0
            lastSize = nil
            // A picture is coming in: open the file now, so the first frame isn't held up by it.
            if let info = lastFrameInfo, let last = lastFrameHost, HostClock.now() - last < RecorderHealth.noSignalAfter {
                _ = openPendingTake(width: info.width, height: info.height, rate: info.rate)
            }
            publish()
        }
    }

    /// Opens the pending take's file. False (and the take abandoned) if it can't be.
    private func openPendingTake(width: Int, height: Int, rate: FrameRate) -> Bool {
        guard let request = pending else { return writer != nil }
        do {
            writer = try TakeWriter(request: request, width: width, height: height, videoRate: rate)
            pending = nil
            status.health.softwareEncoder = !TakeWriter.hasHardwareEncoder(request.codec)
            return true
        } catch {
            pending = nil
            recordingFlag.withLock { $0 = false }
            status.recording = false
            let message = (error as? RecorderError)?.message ?? error.localizedDescription
            onTakeFinished?(.failure(.failed(message)))
            status.state = .failed(message)
            publish()
            return false
        }
    }

    /// Ends the take; `onTakeFinished` follows once the file is closed.
    func stopTake() {
        queue.async { [self] in finishTake() }
    }

    // MARK: Opening (recorder queue)

    /// Builds the source. Capture devices may need permission first, so this calls back.
    private static func makeSource(_ ref: RecorderSource, done: @escaping @Sendable (Result<RecorderFrameSource, RecorderError>) -> Void) {
        switch ref.kind {
        case .testPattern:
            done(.success(TestPatternFrameSource()))
        case .ndi:
            done(.success(NDIFrameSource(sourceName: ref.id)))
        case .capture:
            @Sendable func pick() {
                guard let device = CaptureFrameSource.devices().first(where: { $0.uniqueID == ref.id }) else {
                    done(.failure(.failed("\(ref.name) isn't connected.")))
                    return
                }
                done(.success(CaptureFrameSource(device: device)))
            }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                pick()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted { pick() } else { done(.failure(.failed("Camera access was declined."))) }
                }
            default:
                done(.failure(.failed("Capture is blocked. Allow Understudy in System Settings › Privacy & Security › Camera.")))
            }
        }
    }

    private func started(_ made: Result<RecorderFrameSource, RecorderError>, generation: Int) {
        guard generation == openGeneration else { return }   // re-opened since
        switch made {
        case .failure(let e):
            status.state = .failed(e.message)
        case .success(let s):
            let problem = s.start(on: queue, deliver: { [weak self] frame in self?.handle(frame) },
                                  fail: { [weak self] message in
                                      guard let self else { return }
                                      self.queue.async {
                                          guard generation == self.openGeneration else { return }
                                          self.status.state = .failed(message)
                                          self.publish()
                                      }
                                  })
            if let problem {
                status.state = .failed(problem)
            } else {
                source = s
                status.state = .open
                status.health.sourceOpen = true
                startStatusTimer()
            }
        }
        publish()
    }

    private func closeSource() {
        source?.stop()
        source = nil
        sourceRef = nil
        statusTimer?.cancel()
        statusTimer = nil
        lastFrameHost = nil
        lastFrameTime = nil
        lastFrameInfo = nil
        measuredFPS = nil
        openGeneration += 1
    }

    private func startStatusTimer() {
        statusTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.tickStatus() }
        statusTimer = t
        t.resume()
    }

    // MARK: Frames (recorder queue)

    private func handle(_ frame: RecorderFrame) {
        let w = CVPixelBufferGetWidth(frame.buffer), h = CVPixelBufferGetHeight(frame.buffer)
        // Measured rate, for sources that don't say.
        if let last = lastFrameTime, frame.time > last {
            let instant = 1 / (frame.time - last)
            measuredFPS = measuredFPS.map { $0 * 0.9 + instant * 0.1 } ?? instant
        }
        lastFrameTime = frame.time
        lastFrameHost = frame.host
        let fps = frame.fps > 0 ? frame.fps : (measuredFPS ?? 0)
        let rate = FrameRate.nearest(fps: fps, dropFrame: dropFrame)
        lastFrameInfo = rate.map { (w, h, $0) }
        if let rate {
            let format = RecorderFormat.videoFormat(height: h, rate: rate)
            status.videoFormat = format
            status.lastVideoFormat = format
            status.signal = "\(w)×\(h) \(rate.rawValue)"
        } else {
            status.signal = String(format: "%d×%d %.2f", w, h, fps)
        }

        if writer == nil, pending != nil {
            guard let rate else {
                // A rate Understudy can't stamp timecode at: say so rather than record garbage.
                pending = nil
                recordingFlag.withLock { $0 = false }
                status.recording = false
                status.state = .failed(String(format: "The source runs at %.2f fps; the recorder needs a broadcast rate.", fps))
                publish()
                return
            }
            guard openPendingTake(width: w, height: h, rate: rate) else { return }
        }

        guard let writer else { return }
        writer.append(frame)
        status.health.droppedFrames = writer.clock.dropped
        status.health.encoderDrops = writer.encoderDrops
        status.health.skippedFrames = writer.clock.skipped
        let tc = Timecode(frameIndex: writer.timecodeIndex(atVideoFrame: writer.clock.lastIndex), rate: writer.timecodeRate)
        status.timecode = tc
        position.withLock {
            $0 = Position(timecode: tc, host: frame.host, rate: writer.timecodeRate)
        }
        if let problem = writer.failure {
            status.state = .failed(problem)
            finishTake()
        }
    }

    private func finishTake() {
        pending = nil
        recordingFlag.withLock { $0 = false }
        status.recording = false
        position.withLock { $0 = nil }
        guard let writer else {
            publish()
            return
        }
        self.writer = nil
        let callback = onTakeFinished
        writer.finish { result in callback?(result) }
        publish()
    }

    private func tickStatus() {
        let now = HostClock.now()
        status.health.secondsSinceFrame = lastFrameHost.map { now - $0 }
        if (status.health.secondsSinceFrame ?? .infinity) > RecorderHealth.noSignalAfter {
            status.videoFormat = nil
            status.signal = nil
        }
        status.health.recording = status.recording
        if let writer {
            status.health.recentEncoderDrops = writer.recentEncoderDrops(now: now)
            if let bytes = writer.fileSize() {
                if let last = lastSize, now - last.at >= 1 {
                    let rate = Double(bytes - last.bytes) / (now - last.at)
                    if rate >= 0 {
                        status.health.bytesPerSecond = status.health.bytesPerSecond.map { $0 * 0.7 + rate * 0.3 } ?? rate
                    }
                    lastSize = (bytes, now)
                } else if lastSize == nil {
                    lastSize = (bytes, now)
                }
            }
        } else {
            status.health.recentEncoderDrops = 0
            status.health.bytesPerSecond = nil
        }
        if now - lastFreeCheck >= 2 {
            lastFreeCheck = now
            freeBytes = (writer?.url.deletingLastPathComponent() ?? folder).flatMap(Self.freeSpace)
        }
        status.health.freeBytes = freeBytes
        if let format = status.lastVideoFormat, let rate = FrameRate.fromVideoFormat(format, dropFrame: dropFrame),
           let h = Int(format.prefix { $0.isNumber }) {
            status.health.estimatedBytesPerSecond = (pending?.codec ?? writer?.codec ?? .h264)
                .estimatedBytesPerSecond(width: h * 16 / 9, height: h, fps: rate.exact)
        }
        publish()
    }

    private func publish() {
        onStatus?(status)
    }

    /// Free space on the volume holding `url` (or its nearest existing parent).
    static func freeSpace(_ url: URL) -> Int64? {
        var u = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: u.path), u.pathComponents.count > 1 { u = u.deletingLastPathComponent() }
        let values = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}

// MARK: - Writing one take

/// One take's file: video plus a timecode track, on the recorder's queue.
final class TakeWriter: @unchecked Sendable {
    let url: URL
    let codec: RecorderCodec
    let request: InternalRecorder.TakeRequest
    let videoRate: FrameRate
    let timecodeRate: FrameRate
    /// Timecode frame index of video frame 0 (set by the first frame).
    private(set) var startTimecode = 0
    private var started = false
    /// The last frame written, repeated into slots no frame arrived for.
    private var lastBuffer: CVPixelBuffer?
    private var lastWritten = -1
    private(set) var clock: RecorderFrameClock
    private(set) var encoderDrops = 0
    private(set) var failure: String?
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let timecode: AVAssetWriterInput
    private let timecodeFormat: CMTimeCodeFormatDescription
    private let videoFrame: (value: Int64, timescale: Int32)
    private let tcFrame: (value: Int64, timescale: Int32)
    /// Next timecode sample (one per second of timecode), counted in timecode frames.
    private var nextTimecodeFrame = 0
    private var dropTimes: [Double] = []
    private let width: Int
    private let height: Int

    init(request: InternalRecorder.TakeRequest, width: Int, height: Int, videoRate: FrameRate) throws {
        self.request = request
        url = request.url
        codec = request.codec
        self.width = width
        self.height = height
        self.videoRate = videoRate
        let tcRate = request.timecodeAtVideoRate ? videoRate : videoRate.ltcRate
        timecodeRate = tcRate
        clock = RecorderFrameClock(fps: videoRate.exact)
        videoFrame = videoRate.frameDuration
        tcFrame = tcRate.frameDuration

        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) { throw RecorderError.failed("\(url.lastPathComponent) already exists.") }
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw RecorderError.failed("Couldn't create \(url.lastPathComponent): \(error.localizedDescription)")
        }
        // Fragments every few seconds: a crash or power cut leaves a file that plays up to the last one.
        writer.movieFragmentInterval = CMTime(seconds: 4, preferredTimescale: 600)

        var settings: [String: Any] = [
            AVVideoCodecKey: Self.codecType(codec),
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !codec.isProRes {
            var props: [String: Any] = [
                AVVideoAverageBitRateKey: codec.targetBitRate(width: width, height: height, fps: videoRate.exact),
                AVVideoExpectedSourceFrameRateKey: videoRate.exact,
                // A keyframe a second and no B-frames: cheap to encode live, quick to scrub.
                AVVideoMaxKeyFrameIntervalKey: videoRate.nominal,
                AVVideoAllowFrameReorderingKey: false,
                kVTCompressionPropertyKey_RealTime as String: true,
            ]
            if codec == .h264 { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            settings[AVVideoCompressionPropertiesKey] = props
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw RecorderError.failed("This Mac can't encode \(codec.label) at \(width)×\(height).")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)

        var format: CMTimeCodeFormatDescription?
        let flags = kCMTimeCodeFlag_24HourMax | (tcRate.isDropFrame ? kCMTimeCodeFlag_DropFrame : 0)
        CMTimeCodeFormatDescriptionCreate(allocator: kCFAllocatorDefault, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                                          frameDuration: CMTime(value: tcFrame.value, timescale: tcFrame.timescale),
                                          frameQuanta: UInt32(tcRate.nominal), flags: flags, extensions: nil,
                                          formatDescriptionOut: &format)
        guard let format else { throw RecorderError.failed("Couldn't make the timecode track.") }
        timecodeFormat = format
        timecode = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: format)
        timecode.expectsMediaDataInRealTime = true

        guard writer.canAdd(video), writer.canAdd(timecode) else { throw RecorderError.failed("Couldn't set up the file's tracks.") }
        writer.add(video)
        writer.add(timecode)
        if video.canAddTrackAssociation(withTrackOf: timecode, type: AVAssetTrack.AssociationType.timecode.rawValue) {
            video.addTrackAssociation(withTrackOf: timecode, type: AVAssetTrack.AssociationType.timecode.rawValue)
        }
        guard writer.startWriting() else {
            throw RecorderError.failed("Couldn't start \(url.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
    }

    static func codecType(_ codec: RecorderCodec) -> AVVideoCodecType {
        switch codec {
        case .h264: return .h264
        case .hevc: return .hevc
        case .proResProxy: return .proRes422Proxy
        case .proRes422: return .proRes422
        }
    }

    /// Whether VideoToolbox has a hardware encoder for `codec` on this Mac.
    static func hasHardwareEncoder(_ codec: RecorderCodec) -> Bool {
        hardwareCache.withLock { cache in
            if let known = cache[codec] { return known }
            var list: CFArray?
            VTCopyVideoEncoderList(nil, &list)
            let wanted = fourCC(codec.fourCC)
            let found = ((list as? [[String: Any]]) ?? []).contains { e in
                (e[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == wanted
                    && (e[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
            }
            cache[codec] = found
            return found
        }
    }

    private static let hardwareCache = OSAllocatedUnfairLock<[RecorderCodec: Bool]>(initialState: [:])

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Timecode frame index for video frame `n`.
    func timecodeIndex(atVideoFrame n: Int) -> Int {
        startTimecode + Int((Double(max(0, n)) * timecodeRate.exact / videoRate.exact).rounded(.down))
    }

    func append(_ frame: RecorderFrame) {
        guard failure == nil else { return }
        if writer.status == .failed {
            failure = writer.error?.localizedDescription ?? "Writing failed."
            return
        }
        guard CVPixelBufferGetWidth(frame.buffer) == width, CVPixelBufferGetHeight(frame.buffer) == height else {
            failure = "The source changed size mid-take; recording stopped."
            return
        }
        if !started {
            // The code at the first frame: the code asked for at REC, plus the time since.
            started = true
            startTimecode = Int(((request.startSeconds + (frame.host - request.startHost)) * timecodeRate.exact).rounded())
        }
        guard let index = clock.place(at: frame.time) else { return }
        // Slots no frame arrived for get the previous picture again, so the file stays constant
        // frame rate (the clock has counted them as dropped). The encoder gets a moment to take
        // them: held copies up to half a frame, then the real frame up to another half (the
        // source buffers or drops upstream meanwhile, which the clock sees as a gap). Copies the
        // encoder still can't take stay a gap, and the previous frame plays longer.
        let half = 0.5 / videoRate.exact
        if let held = lastBuffer, lastWritten + 1 < index {
            let deadline = HostClock.now() + half
            var slot = lastWritten + 1
            while slot < index, waitForEncoder(until: deadline) {
                guard write(held, at: slot) else { return }
                slot += 1
            }
        }
        guard waitForEncoder(until: HostClock.now() + half) else {
            clock.unplace(index)
            encoderDrops += 1
            dropTimes.append(HostClock.now())
            return
        }
        if write(frame.buffer, at: index) { lastBuffer = frame.buffer }
    }

    private func waitForEncoder(until deadline: Double) -> Bool {
        while !video.isReadyForMoreMediaData {
            guard HostClock.now() < deadline else { return false }
            usleep(1000)
        }
        return true
    }

    private func write(_ buffer: CVPixelBuffer, at index: Int) -> Bool {
        let pts = CMTime(value: Int64(index) * videoFrame.value, timescale: videoFrame.timescale)
        writeTimecode(through: pts)
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            failure = writer.error?.localizedDescription ?? "The encoder stopped."
            return false
        }
        lastWritten = index
        return true
    }

    /// Timecode samples, one per second of timecode, written as the video reaches them, so the
    /// writer can interleave and every stretch of the file is covered.
    private func writeTimecode(through pts: CMTime) {
        let step = timecodeRate.nominal
        while true {
            let at = CMTime(value: Int64(nextTimecodeFrame) * tcFrame.value, timescale: tcFrame.timescale)
            guard at <= pts else { return }
            guard timecode.isReadyForMoreMediaData else { return }
            guard let sample = timecodeSample(frame: startTimecode + nextTimecodeFrame, at: at, frames: step) else {
                failure = "Couldn't write timecode."
                return
            }
            timecode.append(sample)
            nextTimecodeFrame += step
        }
    }

    private func timecodeSample(frame: Int, at time: CMTime, frames: Int) -> CMSampleBuffer? {
        var value = Int32(truncatingIfNeeded: frame % timecodeRate.framesPerDay).bigEndian
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferReplaceDataBytes(with: &value, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4) == noErr
        else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: Int64(frames) * tcFrame.value, timescale: tcFrame.timescale),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: timecodeFormat, sampleCount: 1, sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                   sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// The encoder can take another frame now.
    var isReady: Bool { video.isReadyForMoreMediaData }

    func recentEncoderDrops(now: Double) -> Int {
        dropTimes.removeAll { now - $0 > 5 }
        return dropTimes.count
    }

    func fileSize() -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Closes the file. `done` is called (on an AVFoundation thread) with the take.
    func finish(_ done: @escaping @Sendable (Result<RecorderTake, RecorderError>) -> Void) {
        let length = clock.length
        guard length > 0, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            done(.failure(.failed(failure ?? "No frames arrived, so nothing was recorded.")))
            return
        }
        let end = CMTime(value: Int64(length) * videoFrame.value, timescale: videoFrame.timescale)
        // Cover the last stretch of timecode (the session end trims the sample to the video).
        writeTimecode(through: end)
        video.markAsFinished()
        timecode.markAsFinished()
        writer.endSession(atSourceTime: end)
        let take = RecorderTake(
            id: request.takeID, name: url.lastPathComponent, path: url.path, startFrame: startTimecode,
            frames: Int((Double(length) * timecodeRate.exact / videoRate.exact).rounded()), rate: timecodeRate,
            videoFormat: RecorderFormat.videoFormat(height: height, rate: videoRate), codec: codec,
            droppedFrames: clock.dropped)
        nonisolated(unsafe) let writer = writer
        writer.finishWriting {
            if writer.status == .completed {
                done(.success(take))
            } else {
                done(.failure(.failed("Couldn't finish \(take.name): \(writer.error?.localizedDescription ?? "unknown error")")))
            }
        }
    }
}
