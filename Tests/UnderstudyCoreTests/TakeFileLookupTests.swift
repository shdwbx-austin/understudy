import Foundation
import Testing
@testable import UnderstudyCore

@Suite("Take file lookup")
struct TakeFileLookupTests {
    let day16 = Date(timeIntervalSince1970: 1_763_300_000)
    let day17 = Date(timeIntervalSince1970: 1_763_400_000)

    @Test func theNewestOfTwoSameNamedTakesWins() {
        // A deck that starts again at _0001 leaves the same name in two day folders.
        let old = TakeFileLookup.Candidate(path: "/b/2026-11-16/ME 1/_ME_1_0010.mov", modified: day16, folder: "ME 1", day: "2026-11-16")
        let new = TakeFileLookup.Candidate(path: "/b/2026-11-17/ME 1/_ME_1_0010.mov", modified: day17, folder: "ME 1", day: "2026-11-17")
        #expect(TakeFileLookup.best([new, old], deck: "ME 1") == new)
        #expect(TakeFileLookup.best([old, new], deck: "ME 1") == new)
    }

    @Test func theDecksOwnFolderComesFirst() {
        let mine = TakeFileLookup.Candidate(path: "/b/2026-11-16/ME 1/x.mov", modified: day16, folder: "ME 1")
        let other = TakeFileLookup.Candidate(path: "/b/2026-11-17/ME 2/x.mov", modified: day17, folder: "ME 2")
        #expect(TakeFileLookup.best([mine, other], deck: "ME 1") == mine)
        #expect(TakeFileLookup.best([mine, other], deck: "ME 2") == other)
        // No folder for this deck: the newest anywhere.
        #expect(TakeFileLookup.best([mine, other], deck: "Wide") == other)
    }

    @Test func folderNamesMatchHowTheyreWritten() {
        let ftp = TakeFileLookup.Candidate(path: "/b/d/Cam_A/x.mov", modified: day16, folder: "Cam_A")       // FTP backup: "/" → "_"
        let project = TakeFileLookup.Candidate(path: "/p/Cam-A/x.mov", modified: day16, folder: "Cam-A", inProject: true)
        let elsewhere = TakeFileLookup.Candidate(path: "/b/d/Other/x.mov", modified: day17, folder: "Other")
        #expect(TakeFileLookup.best([ftp, elsewhere], deck: "Cam/A") == ftp)
        #expect(TakeFileLookup.best([project, elsewhere], deck: "Cam/A") == project)
        #expect(TakeFileLookup.best([ftp, elsewhere], deck: "cam/a") == ftp)
    }

    @Test func aProjectCopyOfTheSameRecordingWinsATie() {
        let backup = TakeFileLookup.Candidate(path: "/b/2026-11-17/ME 1/x.mov", modified: day17, folder: "ME 1")
        let copy = TakeFileLookup.Candidate(path: "/p/ME 1/x.mov", modified: day17.addingTimeInterval(1), folder: "ME 1", inProject: true)
        #expect(TakeFileLookup.best([backup, copy], deck: "ME 1") == copy)
        #expect(TakeFileLookup.best([copy, backup], deck: "ME 1") == copy)
        // An older project copy loses to a newer backup with the same name.
        let stale = TakeFileLookup.Candidate(path: "/p/ME 1/x.mov", modified: day16, folder: "ME 1", inProject: true)
        #expect(TakeFileLookup.best([stale, backup], deck: "ME 1") == backup)
    }

    @Test func copiesOnlyWhenThereIsRoom() {
        #expect(!TakeFileLookup.fits(size: 197_086_512_853, available: 61_000_000_000))
        #expect(TakeFileLookup.fits(size: 166_890_041, available: 61_000_000_000))
        #expect(!TakeFileLookup.fits(size: 55_000_000_000, available: 61_000_000_000))  // inside the 10 GB margin
    }

    @Test func settingsDefaultToPlayingInPlace() throws {
        #expect(!AppSettings().copyTakesIntoProject)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"backupFolder":"/b"}"#.utf8))
        #expect(!old.copyTakesIntoProject)
    }
}
