import AppKit
import Foundation
import UnderstudyCore

/// Projects on disk: where they live, the recent list, and opening, creating and saving them.
/// Files brought into a project (song lists, audio) are copied into its objects folder.
@MainActor
final class ProjectManager: ObservableObject {
    struct Recent: Codable, Identifiable, Equatable {
        var path: String
        var name: String
        var opened: Date
        var id: String { path }
    }

    @Published private(set) var current: ProjectLayout?
    @Published private(set) var recents: [Recent] = []
    /// Files being copied into the project right now.
    @Published private(set) var copying = 0
    @Published var lastError: String?

    /// Where new projects go and Open… starts.
    @Published var root: URL {
        didSet { UserDefaults.standard.set(root.path, forKey: Self.rootKey) }
    }
    /// Open the last project straight away at launch (a show machine), instead of the start window.
    @Published var reopenLastAtLaunch: Bool {
        didSet { UserDefaults.standard.set(reopenLastAtLaunch, forKey: Self.reopenKey) }
    }

    private static let rootKey = "understudy.projectsRoot"
    private static let recentsKey = "understudy.recentProjects"
    private static let reopenKey = "understudy.reopenLastProject"
    private var lastHistory = Date.distantPast
    private let copyQueue = DispatchQueue(label: "understudy.project-copy", qos: .utility)

    static var defaultRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Understudy Projects", isDirectory: true)
    }

    init() {
        let defaults = UserDefaults.standard
        root = defaults.string(forKey: Self.rootKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultRoot
        reopenLastAtLaunch = defaults.bool(forKey: Self.reopenKey)
        if let data = defaults.data(forKey: Self.recentsKey), let list = try? JSONDecoder().decode([Recent].self, from: data) {
            recents = list
        }
    }

    // MARK: Recents

    /// Recent projects that still exist, newest first.
    var availableRecents: [Recent] {
        recents.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func remember(_ layout: ProjectLayout) {
        recents.removeAll { $0.path == layout.file.path }
        recents.insert(Recent(path: layout.file.path, name: layout.name, opened: Date()), at: 0)
        recents = Array(recents.prefix(20))
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: Self.recentsKey) }
    }

    func forget(_ recent: Recent) {
        recents.removeAll { $0.id == recent.id }
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: Self.recentsKey) }
    }

    // MARK: Open, create, save

    /// Reads a project, resolving its file paths to absolute ones.
    func read(_ layout: ProjectLayout) throws -> ProjectFile {
        let data = try Data(contentsOf: layout.file)
        var file = try ProjectFile.decoder().decode(ProjectFile.self, from: data)
        for i in file.show.songs.indices {
            if let p = file.show.songs[i].audioPath { file.show.songs[i].audioPath = layout.resolved(p) }
        }
        return file
    }

    /// Makes `layout` the open project (after it's been read and applied).
    func didOpen(_ layout: ProjectLayout) {
        current = layout
        lastHistory = Date.distantPast
        try? layout.createFolders()
        remember(layout)
    }

    /// Creates a new project folder under `root` and writes its first file.
    func create(named name: String, file: ProjectFile) throws -> ProjectLayout {
        let layout = ProjectLayout(folder: ProjectLayout.folder(named: name, in: root))
        guard !FileManager.default.fileExists(atPath: layout.file.path) else {
            throw NSError(domain: "Understudy", code: 1, userInfo: [NSLocalizedDescriptionKey: "A project called “\(layout.name)” already exists in \(root.lastPathComponent)."])
        }
        try layout.createFolders()
        var f = file
        f.name = layout.name
        try write(f, to: layout)
        return layout
    }

    func close() { current = nil }

    /// Writes the project (paths inside it stored relative); every 5 minutes the previous version
    /// is kept in history/ first, like disguise.
    func save(_ file: ProjectFile) {
        guard let layout = current else { return }
        do {
            if Date().timeIntervalSince(lastHistory) > 300, FileManager.default.fileExists(atPath: layout.file.path) {
                let n = layout.lastHistoryNumber() + 1
                try? FileManager.default.copyItem(at: layout.file, to: layout.historyFile(number: n, at: Date()))
                pruneHistory(layout)
                lastHistory = Date()
            }
            try write(file, to: layout)
            lastError = nil
        } catch {
            lastError = "Couldn't save \(layout.name): \(error.localizedDescription)"
        }
    }

    private func write(_ file: ProjectFile, to layout: ProjectLayout) throws {
        var f = file
        f.modified = Date()
        for i in f.show.songs.indices {
            if let p = f.show.songs[i].audioPath { f.show.songs[i].audioPath = layout.stored(p) }
        }
        let data = try ProjectFile.encoder().encode(f)
        try data.write(to: layout.file, options: .atomic)
    }

    private func pruneHistory(_ layout: ProjectLayout) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: layout.history, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(ProjectLayout.historyKeep) { try? fm.removeItem(at: old) }
    }

    // MARK: Bringing files in

    /// Copies a small file into objects/<asset>/ now; returns the copy.
    func adopt(_ url: URL, as asset: ProjectLayout.Asset) -> URL? {
        guard let layout = current, !layout.isInside(url.path) else { return nil }
        let fm = FileManager.default
        let dest = layout.destination(for: url, asset: asset) { Self.same(url, $0) }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: url, to: dest) }
            return dest
        } catch {
            lastError = "Couldn't copy \(url.lastPathComponent) into the project: \(error.localizedDescription)"
            return nil
        }
    }

    /// Copies audio into objects/AudioFile/ in the background; `done` gets the copy's path.
    func adoptAudio(_ path: String, done: @escaping @MainActor @Sendable (String) -> Void) {
        guard let layout = current, !layout.isInside(path), FileManager.default.fileExists(atPath: path) else { return }
        let src = URL(fileURLWithPath: path)
        let dest = layout.destination(for: src, asset: .audio) { Self.same(src, $0) }
        copying += 1
        copyQueue.async {
            let fm = FileManager.default
            var result: Result<String, Error>
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: dest.path) {
                    // Copy beside, then move into place, so a half-copied file is never used.
                    let partial = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).partial")
                    try? fm.removeItem(at: partial)
                    try fm.copyItem(at: src, to: partial)
                    try fm.moveItem(at: partial, to: dest)
                }
                result = .success(dest.path)
            } catch {
                result = .failure(error)
            }
            let outcome = result
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.copying -= 1
                    switch outcome {
                    case .success(let copy):
                        // Only if this project is still the open one.
                        if self.current == layout { done(copy) }
                    case .failure(let error):
                        self.lastError = "Couldn't copy \(src.lastPathComponent) into the project: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Same size and modification date: the copy already there is this file.
    nonisolated static func same(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let x = try? fm.attributesOfItem(atPath: a.path), let y = try? fm.attributesOfItem(atPath: b.path) else { return false }
        return (x[.size] as? NSNumber) == (y[.size] as? NSNumber)
            && abs(((x[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince((y[.modificationDate] as? Date) ?? .distantFuture)) < 2
    }

    // MARK: Panels

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = root
        panel.message = "Where Understudy keeps projects (and where Open… starts)."
        if panel.runModal() == .OK, let url = panel.url { root = url }
    }

    func chooseProject() -> ProjectLayout? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: ProjectLayout.fileExtension) ?? .data, .folder]
        panel.directoryURL = root
        panel.message = "Choose an Understudy project (its folder or .understudy file)."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let layout = ProjectLayout.project(at: url) else {
            lastError = "\(url.lastPathComponent) isn't an Understudy project."
            return nil
        }
        return layout
    }
}
