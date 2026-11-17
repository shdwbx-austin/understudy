@preconcurrency import AVFoundation
import Foundation
import UnderstudyCore

/// What the Understudy recorder can record from: capture devices, NDI sources and the test
/// pattern. Refreshed when Assign decks opens (NDI sources take a moment to answer).
@MainActor
final class RecorderSources: ObservableObject {
    @Published private(set) var capture: [RecorderSource] = []
    @Published private(set) var ndi: [RecorderSource] = []
    @Published private(set) var searchingNDI = false

    var ndiAvailable: Bool { NDIFinder.shared.isAvailable }

    var all: [RecorderSource] { capture + ndi + [.testPattern] }

    func refresh() {
        capture = CaptureFrameSource.devices().map { RecorderSource(kind: .capture, id: $0.uniqueID, name: $0.localizedName) }
        guard ndiAvailable, !searchingNDI else { return }
        searchingNDI = true
        NDIFinder.shared.list(wait: 1.5) { [weak self] names in
            guard let self else { return }
            // Understudy's own outputs on this Mac carry the Playback LUT and are copies of the
            // decks' recordings: never offered.
            self.ndi = names.filter { !NDIFinder.isOwnOutput($0) }.sorted().map { RecorderSource(kind: .ndi, id: $0, name: $0) }
            self.searchingNDI = false
        }
    }
}
