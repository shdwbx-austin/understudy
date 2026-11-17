import Foundation
import UnderstudyCore

/// Each deck's .cube LUT (none unless the user picks one), kept in its deck settings so it's saved
/// with the project, and handed to the viewer, which applies it on screen and on NDI.
extension AppModel {
    func inputTransform(deck id: Int) -> InputTransform {
        settings.decks.indices.contains(id) ? settings.decks[id].inputTransform : .none
    }

    func setInputTransform(_ transform: InputTransform, deck id: Int) {
        guard settings.decks.indices.contains(id) else { return }
        settings.decks[id].inputTransform = transform
    }

    /// Uses a .cube file for deck `id`: read first (nil on success, else why not), then copied
    /// into the project's objects/LUT/ so the project carries it. Loading the same file again
    /// re-reads it.
    @discardableResult
    func useLUT(_ url: URL, deck id: Int) -> String? {
        guard settings.decks.indices.contains(id) else { return nil }
        do {
            _ = try CubeLUT.read(url)
        } catch {
            return "\(url.lastPathComponent) isn't a LUT Understudy can use. \(error.localizedDescription)"
        }
        let kept = projects.adopt(url, as: .lut) ?? url
        let transform = InputTransform.lut(path: kept.path)
        VideoGrade.forget(transform)
        if settings.decks[id].inputTransform == transform {
            viewer.regrade(deck: id)
        } else {
            settings.decks[id].inputTransform = transform
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

    /// Hands the decks' transforms to the viewer (at launch and when they change).
    func syncViewerTransforms() {
        viewer.setTransforms(Dictionary(settings.decks.map { ($0.id, $0.inputTransform) }, uniquingKeysWith: { a, _ in a }))
    }
}
