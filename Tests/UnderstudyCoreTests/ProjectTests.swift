import Foundation
import Testing
@testable import UnderstudyCore

@Suite("Projects")
struct ProjectTests {
    func tempRoot() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("understudy-project-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func layoutMirrorsDisguise() throws {
        let root = tempRoot()
        let p = ProjectLayout(folder: ProjectLayout.folder(named: "RKS 2026: Summer/TRX", in: root))
        #expect(p.name == "RKS 2026- Summer-TRX")
        #expect(p.file.lastPathComponent == "RKS 2026- Summer-TRX.understudy")
        try p.createFolders()
        for sub in ["history", "objects/AudioFile", "objects/SongList", "objects/Export", "internal/analysis"] {
            var dir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: p.folder.appendingPathComponent(sub).path, isDirectory: &dir) && dir.boolValue)
        }
        #expect(ProjectLayout.project(at: p.file) == p)
    }

    @Test func pathsInsideAreRelative() {
        let p = ProjectLayout(folder: URL(fileURLWithPath: "/Shows/RKS"))
        #expect(p.stored("/Shows/RKS/objects/AudioFile/Heart.wav") == "objects/AudioFile/Heart.wav")
        #expect(p.stored("/Users/a/Dropbox/Heart.wav") == "/Users/a/Dropbox/Heart.wav")
        #expect(p.stored("/Shows/RKS2/x.wav") == "/Shows/RKS2/x.wav")     // a sibling folder isn't inside
        #expect(p.resolved("objects/AudioFile/Heart.wav") == "/Shows/RKS/objects/AudioFile/Heart.wav")
        #expect(p.resolved("/abs/x.wav") == "/abs/x.wav")
        #expect(p.isInside("/Shows/RKS/objects/AudioFile/a.wav") && !p.isInside("/tmp/a.wav"))
    }

    @Test func copiesGetUniqueNames() throws {
        let root = tempRoot()
        let p = ProjectLayout(folder: root.appendingPathComponent("Show"))
        try p.createFolders()
        let dir = p.objects(.audio)
        try Data("a".utf8).write(to: dir.appendingPathComponent("Heart.wav"))
        let src = URL(fileURLWithPath: "/elsewhere/Heart.wav")
        #expect(p.destination(for: src, asset: .audio, sameFile: { _ in true }).lastPathComponent == "Heart.wav")   // same file: reuse
        #expect(p.destination(for: src, asset: .audio, sameFile: { _ in false }).lastPathComponent == "Heart 2.wav")
    }

    @Test func historyNamesAndNumbers() throws {
        let p = ProjectLayout(folder: tempRoot().appendingPathComponent("cb264"))
        try p.createFolders()
        var c = Calendar(identifier: .gregorian); c.timeZone = .current
        let date = c.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 2, minute: 40, second: 4, nanosecond: 643_000_000))!
        let f = p.historyFile(number: 10, at: date)
        #expect(f.lastPathComponent == "cb264_history10__14_sep_2026_02h40m04s643ms.understudy")
        #expect(p.lastHistoryNumber() == 0)
        try Data().write(to: f)
        try Data().write(to: p.historyFile(number: 3, at: date))
        #expect(p.lastHistoryNumber() == 10)
    }

    @Test func projectFileRoundTripAndOldFiles() throws {
        var file = ProjectFile(name: "RKS")
        file.show.songs = [Song(name: "Heart", start: Timecode("03:20:00:00")!, duration: 200)]
        file.show.markers = [Marker(frame: 360_000, kind: .pyro, label: "Gerbs")]
        file.decks = (0..<6).map { DeckConfig(id: $0, name: "CAM \($0 + 1)", host: "10.0.0.\($0 + 10)") }
        file.recordNaming.artist = "RKS"
        file.targets.ma3Host = "10.0.0.50"
        let data = try ProjectFile.encoder().encode(file)
        let back = try ProjectFile.decoder().decode(ProjectFile.self, from: data)
        #expect(back.show == file.show && back.decks == file.decks && back.recordNaming == file.recordNaming && back.targets == file.targets)
        // A minimal file still opens, with defaults.
        let minimal = try ProjectFile.decoder().decode(ProjectFile.self, from: Data(#"{"name":"X"}"#.utf8))
        #expect(minimal.decks.count == AppSettings.defaultDeckCount && minimal.show.songs.isEmpty)
    }
}
