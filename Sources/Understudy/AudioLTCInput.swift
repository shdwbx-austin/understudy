import AVFoundation
import Accelerate
import CoreAudio
import os
import UnderstudyCore

enum HostClock {
    static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channels: Int
    /// Core Audio model UID (identifies the driver, e.g. Dante Virtual Soundcard's).
    var model = ""
}

enum AudioDeviceCatalog {
    static func inputDevices() -> [AudioInputDevice] { devices(scope: kAudioDevicePropertyScopeInput) }
    static func outputDevices() -> [AudioInputDevice] { devices(scope: kAudioDevicePropertyScopeOutput) }

    /// Output channels on a device (nil UID = the system's default output).
    static func outputChannels(uid: String?) -> Int {
        if let uid { return outputDevices().first { $0.uid == uid }?.channels ?? 0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return 0 }
        return channelCount(device, scope: kAudioDevicePropertyScopeOutput)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        (outputDevices() + inputDevices()).first { $0.uid == uid }?.id
    }

    private static func devices(scope: AudioObjectPropertyScope) -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = channelCount(id, scope: scope)
            guard channels > 0 else { return nil }
            return AudioInputDevice(
                id: id,
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                name: stringProperty(id, kAudioObjectPropertyName) ?? "Device \(id)",
                channels: channels,
                model: stringProperty(id, kAudioDevicePropertyModelUID) ?? ""
            )
        }
    }

    /// Calls `changed` on the main queue whenever audio devices appear or disappear.
    static func observeDevices(_ changed: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in
            changed()
        }
    }

    /// The system's default input device.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    /// Input channel names as the device reports them ("Analog 1", "Mic/Line 2"…), or "" where it doesn't.
    static func inputChannelNames(_ id: AudioDeviceID, count: Int) -> [String] {
        (1...max(1, count)).prefix(count).map { channel in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyElementName,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: AudioObjectPropertyElement(channel)
            )
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectHasProperty(id, &address),
                  AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
                  let value
            else { return "" }
            return value.takeRetainedValue() as String
        }
    }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Reads an audio input on the audio thread: decodes LTC from one channel and meters every channel.
///
/// One engine is kept for the app's lifetime. Changing channel never touches it (the tap just
/// reads a different channel); changing device stops it, points it at the new device and restarts
/// it. Tearing engines down and building new ones in quick succession can leave the new one with
/// no audio, which is why it's not done.
final class AudioLTCInput {
    /// Peak level per channel (linear, 0…1), about 20 times a second.
    typealias LevelHandler = @Sendable ([Float]) -> Void

    struct Event: Sendable {
        let timecode: Timecode
        let dropFrame: Bool
        /// Host time (seconds) at which the decoded frame ended.
        let boundaryTime: Double
        /// The same moment on the audio sample clock (seconds since the input started); steadier
        /// than host time, so it's what the rate detector measures with.
        let sampleTime: Double
    }

    enum InputError: LocalizedError {
        case deviceSelect(OSStatus)
        case noInput

        var errorDescription: String? {
            switch self {
            case .deviceSelect(let status): return "Couldn’t select the audio device (\(status))."
            case .noInput: return "The selected device has no usable input."
            }
        }
    }

    /// State shared between the main thread and the audio thread.
    private struct Shared {
        var channel = 0
        /// Bumped on every channel change so the audio thread resets its decoder.
        var generation = 0
        /// Host time of the last buffer received.
        var lastBuffer = 0.0
    }

    /// Peak accumulator, touched only on the audio thread.
    private final class Meter: @unchecked Sendable {
        var peaks: [Float]
        var samples = 0
        let interval: Int
        init(channels: Int, interval: Int) {
            peaks = Array(repeating: 0, count: channels)
            self.interval = interval
        }
    }

    private let engine = AVAudioEngine()
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private(set) var isRunning = false
    /// Channels on the open input (0 when closed).
    private(set) var channelCount = 0

    /// Seconds since the input last delivered audio (0 when not running).
    var secondsSinceLastBuffer: Double {
        guard isRunning else { return 0 }
        let last = shared.withLock { $0.lastBuffer }
        return HostClock.now() - last
    }

    /// Switches the LTC channel without restarting the input.
    func setChannel(_ channel: Int) {
        shared.withLock {
            $0.channel = channel
            $0.generation += 1
        }
    }

    func start(
        deviceID: AudioDeviceID?,
        channel: Int,
        onFrame: @escaping @Sendable (Event) -> Void,
        onLevels: @escaping LevelHandler
    ) throws {
        stop()
        let input = engine.inputNode
        var device = deviceID ?? AudioDeviceCatalog.defaultInputDeviceID() ?? 0
        if device != 0, let unit = input.audioUnit {
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw InputError.deviceSelect(status) }
        }
        // The device's own format: all of its channels, at its sample rate. After switching
        // devices the node's output format can still describe the previous device; tapping
        // with the hardware format applies the new one.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw InputError.noInput }

        let sampleRate = format.sampleRate
        let channelTotal = Int(format.channelCount)
        let decoder = LTCDecoder(sampleRate: sampleRate)
        let meter = Meter(channels: channelTotal, interval: Int(sampleRate / 20))
        let shared = self.shared
        var seenGeneration = -1

        shared.withLock {
            $0.channel = channel
            $0.lastBuffer = HostClock.now()
        }

        input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, when in
            let now = HostClock.now()
            let (selected, generation) = shared.withLock { state -> (Int, Int) in
                state.lastBuffer = now
                return (state.channel, state.generation)
            }
            guard let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let available = min(channelTotal, Int(buffer.format.channelCount))

            for c in 0..<available {
                var peak: Float = 0
                vDSP_maxmgv(channels[c], 1, &peak, vDSP_Length(count))
                meter.peaks[c] = max(meter.peaks[c], peak)
            }
            meter.samples += count
            if meter.samples >= meter.interval {
                onLevels(meter.peaks)
                meter.peaks = Array(repeating: 0, count: channelTotal)
                meter.samples = 0
            }

            if generation != seenGeneration {
                seenGeneration = generation
                decoder.reset()   // new channel, new signal
            }
            guard selected >= 0, selected < available else { return }
            let bufferStart = when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime)
                : now - Double(count) / sampleRate
            let firstSample = decoder.sampleCount
            decoder.process(channels[selected], count: count) { frame in
                let offset = Double(frame.boundarySample - firstSample) / sampleRate
                onFrame(Event(
                    timecode: frame.timecode,
                    dropFrame: frame.dropFrameFlag,
                    boundaryTime: bufferStart + offset,
                    sampleTime: Double(frame.boundarySample) / sampleRate
                ))
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
        channelCount = channelTotal
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        channelCount = 0
    }
}
