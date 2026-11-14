import AVFoundation
import CoreAudio
import Cam4ProgCore

enum HostClock {
    static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channels: Int
}

enum AudioDeviceCatalog {
    static func inputDevices() -> [AudioInputDevice] {
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
            let channels = inputChannelCount(id)
            guard channels > 0 else { return nil }
            return AudioInputDevice(
                id: id,
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                name: stringProperty(id, kAudioObjectPropertyName) ?? "Device \(id)",
                channels: channels
            )
        }
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
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

/// Reads one channel of an audio input and decodes LTC on the audio thread.
final class AudioLTCInput {
    struct Event: Sendable {
        let timecode: Timecode
        let dropFrame: Bool
        /// Host time (seconds) at which the decoded frame ended.
        let boundaryTime: Double
        let estimatedFPS: Double
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

    private var engine = AVAudioEngine()
    private var running = false

    func start(deviceID: AudioDeviceID?, channel: Int, onFrame: @escaping @Sendable (Event) -> Void) throws {
        stop()
        engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceID, let unit = input.audioUnit {
            var device = deviceID
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
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw InputError.noInput }

        let sampleRate = format.sampleRate
        let channelIndex = min(max(0, channel), Int(format.channelCount) - 1)
        let decoder = LTCDecoder(sampleRate: sampleRate)

        input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, when in
            guard let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let bufferStart = when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime)
                : HostClock.now() - Double(count) / sampleRate
            let firstSample = decoder.sampleCount
            decoder.process(channels[channelIndex], count: count) { frame in
                let offset = Double(frame.boundarySample - firstSample) / sampleRate
                onFrame(Event(
                    timecode: frame.timecode,
                    dropFrame: frame.dropFrameFlag,
                    boundaryTime: bufferStart + offset,
                    estimatedFPS: decoder.estimatedFrameRate
                ))
            }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}
