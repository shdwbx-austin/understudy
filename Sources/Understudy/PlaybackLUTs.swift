import Foundation
import UnderstudyCore

/// Playback LUTs: a .cube per feed for Understudy's own playback (the viewer and NDI out), kept
/// in the playback settings (saved with the project, apart from the deck list). Only the viewer
/// applies them; decks, their outputs and their recordings are never touched.
extension AppModel {
    func playbackLUT(deck id: Int) -> InputTransform {
        guard settings.decks.indices.contains(id) else { return .none }
        return settings.playback.lut(feed: PlaybackLUTSettings.feed(settings.decks[id]))
    }

    func setPlaybackLUT(_ transform: InputTransform, deck id: Int) {
        guard settings.decks.indices.contains(id) else { return }
        settings.playback.setLUT(transform, feed: PlaybackLUTSettings.feed(settings.decks[id]))
    }

    /// Uses a .cube file as deck `id`'s Playback LUT: read first (nil on success, else why not),
    /// then copied into the project's objects/LUT/ so the project carries it. Loading the same
    /// file again re-reads it.
    @discardableResult
    func useLUT(_ url: URL, deck id: Int) -> String? {
        guard settings.decks.indices.contains(id) else { return nil }
        do {
            _ = try LUTFile.read(url)
        } catch {
            return "\(url.lastPathComponent) isn't a LUT Understudy can use. \(error.localizedDescription)"
        }
        let kept = projects.adopt(url, as: .lut) ?? url
        let transform = InputTransform.lut(path: kept.path)
        VideoGrade.forget(transform)
        if playbackLUT(deck: id) == transform {
            viewer.regrade(deck: id)
        } else {
            setPlaybackLUT(transform, deck: id)
        }
        return nil
    }

    /// The .cube files already in the open project, for the menu.
    var projectLUTs: [String] {
        guard let layout = projects.current else { return [] }
        let dir = layout.objects(.lut)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".cube") }.sorted()
            .map { dir.appendingPathComponent($0).path }
    }

    /// Each deck's Playback LUT, by its feed, as the viewer wants them (by deck slot).
    var viewerLUTs: [Int: InputTransform] {
        Dictionary(settings.decks.map { ($0.id, settings.playback.lut(feed: PlaybackLUTSettings.feed($0))) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// Copies Playback LUTs that live outside the open project into its objects/LUT/ (e.g. one
    /// chosen before a project was open), so the project carries them.
    func adoptPlaybackLUTs() {
        guard let layout = projects.current else { return }
        var playback = settings.playback
        for (feed, path) in playback.luts where !layout.isInside(path) && FileManager.default.fileExists(atPath: path) {
            if let copy = projects.adopt(URL(fileURLWithPath: path), as: .lut) { playback.luts[feed] = copy.path }
        }
        if playback != settings.playback { settings.playback = playback }
    }

    /// Hands the Playback LUTs to the viewer (at launch, and when they or the decks' names change).
    func syncViewerTransforms() {
        viewer.setTransforms(viewerLUTs)
    }
}
