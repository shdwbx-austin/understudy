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

    // MARK: The choice persisting

    @Test func choiceSurvivesSettingsAndProjects() throws {
        var settings = AppSettings()
        settings.decks[0].inputTransform = .lut(path: "/Users/a/LUTs/SLog3_to_709.cube")
        settings.decks[1].inputTransform = .lut(path: "/Shows/RKS/objects/LUT/Show.cube")
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(back.decks[0].inputTransform == .lut(path: "/Users/a/LUTs/SLog3_to_709.cube"))
        #expect(back.decks[1].inputTransform == .lut(path: "/Shows/RKS/objects/LUT/Show.cube"))
        #expect(back.decks[2].inputTransform == .none)

        let file = ProjectFile(name: "RKS", decks: settings.decks)
        let reread = try ProjectFile.decoder().decode(ProjectFile.self, from: ProjectFile.encoder().encode(file))
        #expect(reread.decks.map(\.inputTransform) == settings.decks.map(\.inputTransform))
    }

    @Test func projectLUTsAreStoredRelative() throws {
        let layout = ProjectLayout(folder: URL(fileURLWithPath: "/Shows/RKS"))
        var file = ProjectFile(name: "RKS")
        file.decks[0].inputTransform = .lut(path: "/Shows/RKS/objects/LUT/Show.cube")
        file.decks[1].inputTransform = .lut(path: "/Users/a/LUTs/Other.cube")
        file.mapPaths(layout, toStored: true)
        #expect(file.decks[0].inputTransform == .lut(path: "objects/LUT/Show.cube"))
        #expect(file.decks[1].inputTransform == .lut(path: "/Users/a/LUTs/Other.cube"))
        #expect(file.decks[2].inputTransform == .none)
        let json = String(decoding: try ProjectFile.encoder().encode(file), as: UTF8.self)
        #expect(json.contains("\"lut\" : \"objects\\/LUT\\/Show.cube\""))
        file.mapPaths(layout, toStored: false)
        #expect(file.decks[0].inputTransform == .lut(path: "/Shows/RKS/objects/LUT/Show.cube"))
    }

    @Test func nothingIsConvertedUnlessALUTIsChosen() throws {
        // New decks and settings have no transform.
        #expect(DeckConfig(id: 0, name: "ME 1", host: "").inputTransform == .none)
        #expect(AppSettings().decks.allSatisfy { $0.inputTransform == .none })
        #expect(ProjectFile(name: "New").decks.allSatisfy { $0.inputTransform == .none })
        // A deck saved before transforms existed, one with a built-in log conversion from a
        // pre-release build, and an empty one: all play as recorded.
        let json = """
            [{"id": 0, "name": "ME 1", "host": "10.255.255.1"},
             {"id": 1, "name": "ME 2", "host": "", "inputTransform": {"log": "sLog3"}},
             {"id": 2, "name": "AUX", "host": "", "inputTransform": {}},
             {"id": 3, "name": "ME 4", "host": "", "inputTransform": {"lut": ""}}]
            """
        let decks = try JSONDecoder().decode([DeckConfig].self, from: Data(json.utf8))
        #expect(decks.map(\.inputTransform) == [.none, .none, .none, .none])
        // None is written as an empty object, never as a conversion.
        let written = String(decoding: try JSONEncoder().encode(decks[1]), as: UTF8.self)
        #expect(written.contains("\"inputTransform\":{}"))
        #expect(decks[1].name == "ME 2")
    }
}
