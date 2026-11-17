import AVFoundation
import Foundation

/// The app's HostClock (Sources/Understudy/AudioLTCInput.swift), without the audio input it lives with.
enum HostClock {
    static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

/// Stands in for the app's TimelineModel, which only the take stores need here: its store
/// directory, always the harness's temp `UNDERSTUDY_STORE`.
enum TimelineModel {
    nonisolated static var storeDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["UNDERSTUDY_STORE"]!, isDirectory: true)
    }
}
