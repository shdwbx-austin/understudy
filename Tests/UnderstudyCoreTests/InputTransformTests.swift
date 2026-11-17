import Foundation
import Testing
@testable import UnderstudyCore

@Suite("Input transforms")
struct InputTransformTests {
    // MARK: .cube parsing

    /// A 2³ identity cube, red fastest, the way Resolve writes them.
    static let identity2 = """
        # Created by hand
        TITLE "Identity 2"
        LUT_3D_SIZE 2

        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """

    @Test func parsesA3DCube() throws {
        let lut = try CubeLUT.parse(Self.identity2)
        #expect(lut.size == 2)
        #expect(lut.title == "Identity 2")
        #expect(lut.values.count == 24)
        // Red changes fastest: entry 1 is (1,0,0), entry 2 is (0,1,0), entry 4 is (0,0,1).
        #expect(Array(lut.values[3..<6]) == [1, 0, 0])
        #expect(Array(lut.values[6..<9]) == [0, 1, 0])
        #expect(Array(lut.values[12..<15]) == [0, 0, 1])
        let s = lut.sample([0.25, 0.5, 0.75])
        #expect(abs(s[0] - 0.25) < 1e-6 && abs(s[1] - 0.5) < 1e-6 && abs(s[2] - 0.75) < 1e-6)
    }

    @Test func toleratesCRLFTabsCommentsAndUnknownKeywords() throws {
        let text = "TITLE \"Look\"\r\nLUT_IN_VIDEO_RANGE\r\nLUT_3D_SIZE\t2\r\n"
            + "0 0 0 # black\r\n1\t0 0\r\n0 1 0\r\n1 1 0\r\n0 0 1\r\n1 0 1\r\n0 1 1\r\n1.0e0 1 1\r\n"
        let lut = try CubeLUT.parse(text)
        #expect(lut.size == 2 && lut.title == "Look")
        #expect(lut.values.last == 1)
    }

    @Test func aBiggerCubeKeepsItsSizeAndOrder() throws {
        let made = CubeLUT.baked(size: 17) { rgb in [rgb[0] * 0.5, rgb[1], 1 - rgb[2]] }
        var text = "LUT_3D_SIZE 17\n"
        for i in 0..<(17 * 17 * 17) {
            text += "\(made.values[i * 3]) \(made.values[i * 3 + 1]) \(made.values[i * 3 + 2])\n"
        }
        let lut = try CubeLUT.parse(text)
        #expect(lut == made)
        let s = lut.sample([0.3, 0.6, 0.2])
        #expect(abs(s[0] - 0.15) < 1e-5 && abs(s[1] - 0.6) < 1e-5 && abs(s[2] - 0.8) < 1e-5)
        #expect(lut.rgbaData().count == 17 * 17 * 17 * 4 * MemoryLayout<Float>.size)
    }

    @Test func rgbaDataIsRedFastestWithOpaqueAlpha() throws {
        let lut = try CubeLUT.parse(Self.identity2)
        let floats = lut.rgbaData().withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(floats.count == 32)
        #expect(Array(floats[4..<8]) == [1, 0, 0, 1])     // entry 1: red
        #expect(Array(floats[16..<20]) == [0, 0, 1, 1])   // entry 4: blue
    }

    @Test func aDomainIsResampledOntoZeroToOne() throws {
        // An identity over inputs 0–2: resampled onto 0–1 it's still the identity.
        let text = """
            LUT_3D_SIZE 2
            DOMAIN_MIN 0 0 0
            DOMAIN_MAX 2 2 2
            0 0 0
            2 0 0
            0 2 0
            2 2 0
            0 0 2
            2 0 2
            0 2 2
            2 2 2
            """
        let lut = try CubeLUT.parse(text)
        let s = lut.sample([0.5, 1, 0])
        #expect(abs(s[0] - 0.5) < 1e-6 && abs(s[1] - 1) < 1e-6 && abs(s[2]) < 1e-6)
    }

    @Test func a1DLutBecomesA3DCube() throws {
        // Squares each channel.
        var text = "TITLE \"Square\"\nLUT_1D_SIZE 5\n"
        for i in 0..<5 { let v = Double(i) / 4; text += "\(v * v) \(v * v) \(v * v)\n" }
        let lut = try CubeLUT.parse(text)
        #expect(lut.size == CubeLUT.bakedSize)
        let s = lut.sample([0.5, 1, 0])
        #expect(abs(s[0] - 0.25) < 0.01 && abs(s[1] - 1) < 1e-6 && abs(s[2]) < 1e-6)
    }

    @Test func badFilesSayWhy() {
        #expect(throws: CubeLUT.ParseError.noSize) { try CubeLUT.parse("0 0 0\n1 1 1\n") }
        #expect(throws: CubeLUT.ParseError.wrongCount(expected: 8, found: 2)) {
            try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 1 1\n")
        }
        #expect(throws: CubeLUT.ParseError.badSize(1)) { try CubeLUT.parse("LUT_3D_SIZE 1\n0 0 0\n") }
        #expect(throws: CubeLUT.ParseError.badSize(256)) { try CubeLUT.parse("LUT_3D_SIZE 256\n") }
        #expect(throws: CubeLUT.ParseError.badLine(2, "0 0")) { try CubeLUT.parse("LUT_3D_SIZE 2\n0 0\n") }
        #expect(throws: CubeLUT.ParseError.badDomain) {
            try CubeLUT.parse("LUT_1D_SIZE 2\nDOMAIN_MIN 1 1 1\nDOMAIN_MAX 1 1 1\n0 0 0\n1 1 1\n")
        }
        #expect(throws: (any Error).self) { try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 nan\n") }
    }

    // MARK: Playback LUTs: a playback setting, saved apart from the decks

    @Test func playbackLUTsSurviveSettingsAndProjects() throws {
        var settings = AppSettings()
        settings.playback.setLUT(.lut(path: "/Users/a/LUTs/SLog3_to_709.cube"), feed: "ME 1")
        settings.playback.setLUT(.lut(path: "/Shows/RKS/objects/LUT/Show.cube"), feed: "ME 2")
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.playback == settings.playback)
        #expect(back.playback.lut(feed: "ME 1") == .lut(path: "/Users/a/LUTs/SLog3_to_709.cube"))
        #expect(back.playback.lut(feed: "AUX 1") == .none)

        let file = ProjectFile(name: "RKS", decks: settings.decks, playback: settings.playback)
        let reread = try ProjectFile.decoder().decode(ProjectFile.self, from: ProjectFile.encoder().encode(file))
        #expect(reread.playback == settings.playback)
        // Not a deck property: the deck list carries no LUT.
        let decksJSON = String(decoding: try JSONEncoder().encode(reread.decks), as: UTF8.self)
        #expect(!decksJSON.contains("lut") && !decksJSON.contains("inputTransform"))
        // None clears it.
        settings.playback.setLUT(.none, feed: "ME 1")
        #expect(settings.playback.luts["ME 1"] == nil)
    }

    @Test func feedsAreNamedLikeTheViewer() {
        #expect(PlaybackLUTSettings.feed(DeckConfig(id: 0, name: " ME 1 ", host: "")) == "ME 1")
        #expect(PlaybackLUTSettings.feed(DeckConfig(id: 2, name: "  ", host: "")) == "Deck 3")
    }

    @Test func projectLUTsAreStoredRelative() throws {
        let layout = ProjectLayout(folder: URL(fileURLWithPath: "/Shows/RKS"))
        var file = ProjectFile(name: "RKS")
        file.playback.setLUT(.lut(path: "/Shows/RKS/objects/LUT/Show.cube"), feed: "ME 1")
        file.playback.setLUT(.lut(path: "/Users/a/LUTs/Other.cube"), feed: "ME 2")
        file.mapPaths(layout, toStored: true)
        #expect(file.playback.luts == ["ME 1": "objects/LUT/Show.cube", "ME 2": "/Users/a/LUTs/Other.cube"])
        let json = String(decoding: try ProjectFile.encoder().encode(file), as: UTF8.self)
        #expect(json.contains("\"playback\" : {"))
        #expect(json.contains("\"ME 1\" : \"objects\\/LUT\\/Show.cube\""))
        file.mapPaths(layout, toStored: false)
        #expect(file.playback.lut(feed: "ME 1") == .lut(path: "/Shows/RKS/objects/LUT/Show.cube"))
    }

    /// Decks as saved by the first version of this feature: a LUT on the deck itself.
    static let legacyDecks = """
        [{"id": 0, "name": "ME 1", "host": "10.255.255.1", "inputTransform": {"lut": "objects/LUT/Show.cube"}},
         {"id": 1, "name": "ME 2", "host": "", "inputTransform": {"log": "sLog3"}},
         {"id": 2, "name": "", "host": "", "inputTransform": {"lut": "/Users/a/LUTs/Aux.cube"}},
         {"id": 3, "name": "ME 4", "host": "", "inputTransform": {}},
         {"id": 4, "name": "ME 5", "host": ""}]
        """

    @Test func oldProjectsMoveDeckLUTsIntoPlayback() throws {
        let json = "{\"name\": \"Old\", \"decks\": \(Self.legacyDecks)}"
        let file = try ProjectFile.decoder().decode(ProjectFile.self, from: Data(json.utf8))
        // The LUTs land in playback, by feed; a built-in log curve (never shipped) is dropped.
        #expect(file.playback.luts == ["ME 1": "objects/LUT/Show.cube", "Deck 3": "/Users/a/LUTs/Aux.cube"])
        // The decks themselves still load, host and all, and carry no LUT any more.
        #expect(file.decks.count == 5 && file.decks[0].host == "10.255.255.1")
        let written = String(decoding: try ProjectFile.encoder().encode(file), as: UTF8.self)
        #expect(!written.contains("inputTransform"))
        // Read back from the new place, the same.
        let again = try ProjectFile.decoder().decode(ProjectFile.self, from: Data(written.utf8))
        #expect(again.playback == file.playback)
    }

    @Test func oldSettingsMoveDeckLUTsIntoPlayback() throws {
        let json = "{\"decks\": \(Self.legacyDecks), \"oscPort\": 9001}"
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.playback.luts == ["ME 1": "objects/LUT/Show.cube", "Deck 3": "/Users/a/LUTs/Aux.cube"])
        #expect(settings.oscPort == 9001 && settings.decks[0].host == "10.255.255.1")
    }

    @Test func savedPlaybackWinsOverLeftoverDeckLUTs() throws {
        let json = "{\"name\": \"X\", \"decks\": \(Self.legacyDecks), \"playback\": {\"luts\": {}}}"
        let file = try ProjectFile.decoder().decode(ProjectFile.self, from: Data(json.utf8))
        #expect(file.playback.luts.isEmpty)
    }

    @Test func nothingIsConvertedUnlessALUTIsChosen() throws {
        #expect(AppSettings().playback.luts.isEmpty)
        #expect(ProjectFile(name: "New").playback.luts.isEmpty)
        // A deck list from before this feature: no LUTs.
        let json = "{\"name\": \"Old\", \"decks\": [{\"id\": 0, \"name\": \"ME 1\", \"host\": \"\"}]}"
        #expect(try ProjectFile.decoder().decode(ProjectFile.self, from: Data(json.utf8)).playback.luts.isEmpty)
        // Anything but a LUT reads as none.
        let none = try JSONDecoder().decode(InputTransform.self, from: Data("{\"log\": \"vLog\"}".utf8))
        #expect(none == .none)
    }
}
