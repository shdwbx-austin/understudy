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

    // MARK: Built-in log curves

    @Test(arguments: LogCurve.allCases)
    func curvesRoundTrip(_ curve: LogCurve) {
        for lin in [0.0, 0.001, 0.01, 0.18, 0.9, 4, 16] {
            #expect(abs(curve.linear(curve.encode(lin)) - lin) < 1e-6 * max(1, lin), "\(curve) at \(lin)")
        }
    }

    @Test func greyLandsWhereTheMakersSay() {
        // 18% grey, as code values / 1023 (Sony 420, ARRI EI 800 ≈ 400, Panasonic 433) and
        // Blackmagic's 0–1 signal (≈ 0.384).
        #expect(abs(LogCurve.sLog3.encode(0.18) * 1023 - 420) < 0.5)
        #expect(abs(LogCurve.logC3.encode(0.18) * 1023 - 400) < 1.5)
        #expect(abs(LogCurve.vLog.encode(0.18) * 1023 - 433) < 1)
        #expect(abs(LogCurve.bmdFilmGen5.encode(0.18) - 0.3836) < 0.001)
    }

    @Test(arguments: LogCurve.allCases)
    func gamutsKeepWhite(_ curve: LogCurve) {
        // Same white as Rec.709 (D65): neutral stays neutral, each row sums to 1.
        for row in LogToRec709(curve).matrix.rows { #expect(abs(row.reduce(0, +) - 1) < 1e-3, "\(curve)") }
    }

    @Test func rec709MatrixIsIdentityToItself() {
        let m = ColorPrimaries.rec709.matrix(to: .rec709)
        for i in 0..<3 { for j in 0..<3 { #expect(abs(m.rows[i][j] - (i == j ? 1 : 0)) < 1e-9) } }
        // And the well-known Rec.709 → XYZ luminance row.
        let y = ColorPrimaries.rec709.toXYZ.rows[1]
        #expect(abs(y[0] - 0.2126) < 1e-3 && abs(y[1] - 0.7152) < 1e-3 && abs(y[2] - 0.0722) < 1e-3)
    }

    @Test(arguments: LogCurve.allCases)
    func logGreyBecomesRec709Grey(_ curve: LogCurve) {
        let t = LogToRec709(curve)
        let grey = t.encodeLinear709([0.18, 0.18, 0.18])
        let out = t.apply(grey)
        let expected = LogToRec709.rec709Encode(0.18)   // 0.409
        for c in out { #expect(abs(c - expected) < 1e-4, "\(curve)") }
        // Black stays black, and a red patch stays red in Rec.709.
        #expect(t.apply(t.encodeLinear709([0, 0, 0])).allSatisfy { abs($0) < 1e-4 })
        let red = t.apply(t.encodeLinear709([0.5, 0.05, 0.05]))
        #expect(abs(red[0] - LogToRec709.rec709Encode(0.5)) < 1e-3)
        #expect(abs(red[1] - LogToRec709.rec709Encode(0.05)) < 1e-3)
    }

    @Test func highlightsRollOffInsteadOfClipping() {
        #expect(LogToRec709.shoulder(0.5) == 0.5)
        #expect(LogToRec709.shoulder(1) < 1 && LogToRec709.shoulder(1) > 0.9)
        #expect(LogToRec709.shoulder(2) > LogToRec709.shoulder(1.5))
        #expect(LogToRec709.shoulder(100) <= 1)
    }

    @Test(arguments: LogCurve.allCases)
    func bakedCubeMatchesTheMaths(_ curve: LogCurve) {
        let t = LogToRec709(curve)
        let cube = t.cube(size: 64)
        func error(_ patch: [Double]) -> Double {
            let input = t.encodeLinear709(patch)
            return zip(t.apply(input), cube.sample(input)).map { abs($0 - $1) }.max() ?? 0
        }
        // Greys and everyday colours: under half an 8-bit step.
        for patch in [[0.18, 0.18, 0.18], [0.005, 0.005, 0.005], [0.6, 0.6, 0.6], [0.35, 0.22, 0.15], [0.1, 0.2, 0.08]] {
            #expect(error(patch) < 1.0 / 512, "\(curve) \(patch)")
        }
        // Saturated colours near the gamut edge (where a channel clips): within a few steps.
        for patch in [[0.5, 0.05, 0.05], [0.02, 0.3, 0.6], [0.9, 0.9, 0.2]] {
            #expect(error(patch) < 1.0 / 64, "\(curve) \(patch)")
        }
    }

    // MARK: The choice persisting

    @Test func choiceSurvivesSettingsAndProjects() throws {
        var settings = AppSettings()
        settings.decks[0].inputTransform = .log(.sLog3)
        settings.decks[1].inputTransform = .lut(path: "/Shows/RKS/objects/LUT/Show.cube")
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(back.decks[0].inputTransform == .log(.sLog3))
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
        file.decks[2].inputTransform = .log(.vLog)
        file.mapPaths(layout, toStored: true)
        #expect(file.decks[0].inputTransform == .lut(path: "objects/LUT/Show.cube"))
        #expect(file.decks[1].inputTransform == .lut(path: "/Users/a/LUTs/Other.cube"))
        #expect(file.decks[2].inputTransform == .log(.vLog))
        let json = String(decoding: try ProjectFile.encoder().encode(file), as: UTF8.self)
        #expect(json.contains("\"lut\" : \"objects\\/LUT\\/Show.cube\""))
        #expect(json.contains("\"log\" : \"vLog\""))
        file.mapPaths(layout, toStored: false)
        #expect(file.decks[0].inputTransform == .lut(path: "/Shows/RKS/objects/LUT/Show.cube"))
    }

    @Test func olderAndNewerFilesStillOpen() throws {
        // A deck saved before transforms existed, and one with a curve from a later version.
        let json = """
            [{"id": 0, "name": "ME 1", "host": "10.255.255.1"},
             {"id": 1, "name": "ME 2", "host": "", "inputTransform": {"log": "someFutureLog"}},
             {"id": 2, "name": "AUX", "host": "", "inputTransform": {}}]
            """
        let decks = try JSONDecoder().decode([DeckConfig].self, from: Data(json.utf8))
        #expect(decks.map(\.inputTransform) == [.none, .none, .none])
        #expect(decks[1].name == "ME 2")
    }
}
