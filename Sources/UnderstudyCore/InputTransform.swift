import Foundation

// MARK: - The choice

/// How a deck's recordings are turned into Rec.709 for the viewer and NDI: left alone, one of
/// the common camera log curves, or a .cube LUT. Saved per deck (`DeckConfig`), so it travels
/// with the project.
public enum InputTransform: Hashable, Sendable, Codable {
    /// Already Rec.709 (or wanted as it is).
    case none
    case log(LogCurve)
    /// A .cube file: absolute in memory, stored relative when it's inside the project.
    case lut(path: String)

    public var title: String {
        switch self {
        case .none: return "None (Rec.709)"
        case .log(let curve): return curve.title
        case .lut(let path): return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }

    /// Short, for a menu label.
    public var shortTitle: String {
        switch self {
        case .none: return "Rec.709"
        case .log(let curve): return curve.shortTitle
        case .lut: return title
        }
    }

    public var lutPath: String? {
        if case .lut(let path) = self { return path }
        return nil
    }

    // {} for none, {"log": "sLog3"} or {"lut": "objects/LUT/Show.cube"}.
    private enum CodingKeys: String, CodingKey { case log, lut }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let curve = try c.decodeIfPresent(LogCurve.self, forKey: .log) {
            self = .log(curve)
        } else if let path = try c.decodeIfPresent(String.self, forKey: .lut), !path.isEmpty {
            self = .lut(path: path)
        } else {
            self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: break
        case .log(let curve): try c.encode(curve, forKey: .log)
        case .lut(let path): try c.encode(path, forKey: .lut)
        }
    }
}

// MARK: - Built-in log curves

/// Common camera log encodings, each with its camera gamut, converted to Rec.709 by
/// `LogToRec709`. Code values follow each maker's spec.
public enum LogCurve: String, Codable, CaseIterable, Sendable, Identifiable {
    case bmdFilmGen5
    case sLog3
    case logC3
    case vLog

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bmdFilmGen5: return "Blackmagic Film Gen 5"
        case .sLog3: return "Sony S-Log3 / S-Gamut3.Cine"
        case .logC3: return "ARRI LogC3 / AWG3 (EI 800)"
        case .vLog: return "Panasonic V-Log / V-Gamut"
        }
    }

    public var shortTitle: String {
        switch self {
        case .bmdFilmGen5: return "BMD Film Gen 5"
        case .sLog3: return "S-Log3"
        case .logC3: return "LogC3"
        case .vLog: return "V-Log"
        }
    }

    /// Sony, ARRI and Panasonic define their curves on 10-bit code values with black above 64
    /// (95, 95, 128 of 1023), i.e. as carried in a video-range (legal) signal, which is how a
    /// HyperDeck records them. Blackmagic's Gen 5 curve is defined on the 0–1 signal itself.
    public var usesCodeValues: Bool { self != .bmdFilmGen5 }

    /// Curve value (0–1, in the maker's own terms) → scene linear (0.18 = mid grey).
    public func linear(_ x: Double) -> Double {
        switch self {
        case .bmdFilmGen5:
            let p = BMDGen5.self
            return x < p.d * p.linCut + p.e ? (x - p.e) / p.d : exp((x - p.c) / p.a) - p.b
        case .sLog3:
            let cv = x * 1023
            return cv >= 171.2102946929 ? pow(10, (cv - 420) / 261.5) * 0.19 - 0.01
                : (cv - 95) * 0.01125 / (171.2102946929 - 95)
        case .logC3:
            let p = LogC3.self
            return x > p.e * p.cut + p.f ? (pow(10, (x - p.d) / p.c) - p.b) / p.a : (x - p.f) / p.e
        case .vLog:
            return x < 0.181 ? (x - 0.125) / 5.6 : pow(10, (x - 0.598206) / 0.241514) - 0.00873
        }
    }

    /// Scene linear → curve value: the camera's side (for tests and test frames).
    public func encode(_ lin: Double) -> Double {
        switch self {
        case .bmdFilmGen5:
            let p = BMDGen5.self
            return lin < p.linCut ? p.d * lin + p.e : p.a * log(lin + p.b) + p.c
        case .sLog3:
            return lin >= 0.01125 ? (420 + log10((lin + 0.01) / 0.19) * 261.5) / 1023
                : (lin * (171.2102946929 - 95) / 0.01125 + 95) / 1023
        case .logC3:
            let p = LogC3.self
            return lin > p.cut ? p.c * log10(p.a * lin + p.b) + p.d : p.e * lin + p.f
        case .vLog:
            return lin < 0.01 ? 5.6 * lin + 0.125 : 0.241514 * log10(lin + 0.00873) + 0.598206
        }
    }

    /// The camera gamut's primaries (red, green, blue) and white, CIE xy.
    public var primaries: ColorPrimaries {
        switch self {
        case .bmdFilmGen5:
            return ColorPrimaries(red: (0.7177215, 0.3171181), green: (0.2280410, 0.8615690),
                                  blue: (0.1005841, -0.0820452), white: (0.3127170, 0.3290312))
        case .sLog3:   // S-Gamut3.Cine
            return ColorPrimaries(red: (0.766, 0.275), green: (0.225, 0.800), blue: (0.089, -0.087), white: ColorPrimaries.d65)
        case .logC3:   // ARRI Wide Gamut 3
            return ColorPrimaries(red: (0.6840, 0.3130), green: (0.2210, 0.8480), blue: (0.0861, -0.1020), white: ColorPrimaries.d65)
        case .vLog:    // V-Gamut
            return ColorPrimaries(red: (0.730, 0.280), green: (0.165, 0.840), blue: (0.100, -0.030), white: ColorPrimaries.d65)
        }
    }

    private enum BMDGen5 {
        static let a = 0.08692876065491224, b = 0.005494072432257808, c = 0.5300133392291939
        static let d = 8.283605932402494, e = 0.09246575342465753, linCut = 0.005
    }

    private enum LogC3 {   // EI 800, scene linear
        static let cut = 0.010591, a = 5.555556, b = 0.052272, c = 0.247190, d = 0.385537, e = 5.367655, f = 0.092809
    }
}

// MARK: - Colour math

public struct ColorPrimaries: Sendable {
    public typealias XY = (x: Double, y: Double)
    public static let d65: XY = (0.3127, 0.3290)
    public static let rec709 = ColorPrimaries(red: (0.64, 0.33), green: (0.30, 0.60), blue: (0.15, 0.06), white: d65)

    public let red: XY, green: XY, blue: XY, white: XY

    public init(red: XY, green: XY, blue: XY, white: XY) {
        self.red = red; self.green = green; self.blue = blue; self.white = white
    }

    /// RGB (linear, in these primaries) → CIE XYZ, white at Y = 1.
    public var toXYZ: Matrix3 {
        func xyz(_ p: XY) -> [Double] { [p.x / p.y, 1, (1 - p.x - p.y) / p.y] }
        let r = xyz(red), g = xyz(green), b = xyz(blue), w = xyz(white)
        let m = Matrix3(rows: [[r[0], g[0], b[0]], [r[1], g[1], b[1]], [r[2], g[2], b[2]]])
        let s = m.inverse * w
        return Matrix3(rows: (0..<3).map { i in (0..<3).map { j in m.rows[i][j] * s[j] } })
    }

    /// Linear RGB in these primaries → linear RGB in `other` (same white, so no adaptation).
    public func matrix(to other: ColorPrimaries) -> Matrix3 { other.toXYZ.inverse * toXYZ }
}

public struct Matrix3: Sendable, Equatable {
    public var rows: [[Double]]

    public init(rows: [[Double]]) { self.rows = rows }

    public static func * (m: Matrix3, v: [Double]) -> [Double] {
        m.rows.map { $0[0] * v[0] + $0[1] * v[1] + $0[2] * v[2] }
    }

    public static func * (a: Matrix3, b: Matrix3) -> Matrix3 {
        Matrix3(rows: (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a.rows[i][$1] * b.rows[$1][j] } } })
    }

    public var inverse: Matrix3 {
        let m = rows
        let a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2], g = m[2][0], h = m[2][1], i = m[2][2]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return Matrix3(rows: [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
                              [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
                              [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]])
    }
}

/// A camera log curve and gamut → Rec.709, the way the built-ins do it:
///
/// 1. the picture's value (0–1, video range as AVFoundation decodes it) → the curve's own value
///    (code values / 1023 for curves defined on them, see `LogCurve.usesCodeValues`);
/// 2. → scene linear, camera gamut → Rec.709 primaries (out-of-gamut negatives clipped);
/// 3. a soft shoulder above 80% linear, so highlights roll off instead of clipping;
/// 4. → the Rec.709 curve. 18% grey lands at 41%, as a Rec.709 camera would put it.
public struct LogToRec709: Sendable {
    public let curve: LogCurve
    public let matrix: Matrix3

    public init(_ curve: LogCurve) {
        self.curve = curve
        matrix = curve.primaries.matrix(to: .rec709)
    }

    /// Video-range picture value → curve value.
    public static func codeValue(fromPicture v: Double) -> Double { (64 + 876 * v) / 1023 }
    /// Curve value → video-range picture value (the camera's side).
    public static func picture(fromCodeValue x: Double) -> Double { (1023 * x - 64) / 876 }

    public func apply(_ rgb: [Double]) -> [Double] {
        let lin = rgb.map { v in curve.linear(curve.usesCodeValues ? Self.codeValue(fromPicture: v) : v) }
        return (matrix * lin).map { Self.rec709Encode(Self.shoulder(max(0, $0))) }
    }

    /// The camera side, for test frames: Rec.709 linear → this curve's picture value.
    public func encodeLinear709(_ rgb: [Double]) -> [Double] {
        (matrix.inverse * rgb).map { lin in
            let x = curve.encode(lin)
            return curve.usesCodeValues ? Self.picture(fromCodeValue: x) : x
        }
    }

    public static let knee = 0.8

    /// Identity up to the knee, then eases towards 1 (continuous slope).
    public static func shoulder(_ y: Double) -> Double {
        guard y > knee else { return y }
        let room = 1 - knee
        return knee + room * (1 - exp(-(y - knee) / room))
    }

    /// ITU-R BT.709 OETF.
    public static func rec709Encode(_ l: Double) -> Double {
        let l = min(max(l, 0), 1)
        return l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099
    }

    /// As a 3D LUT (input and output 0–1 picture values).
    public func cube(size: Int = 64) -> CubeLUT {
        CubeLUT.baked(size: size, title: curve.title) { apply($0) }
    }
}

// MARK: - .cube LUTs

/// A 3D LUT, as in an Adobe/Resolve .cube file: `size`³ RGB entries, red changing fastest,
/// over inputs 0–1. 1D LUTs and other input ranges are baked into this form when read.
public struct CubeLUT: Equatable, Sendable {
    public static let maxSize = 128
    /// 1D LUTs become a 3D LUT this size.
    public static let bakedSize = 33

    public var title: String?
    public let size: Int
    /// size³ × 3 floats, RGB, red fastest then green then blue.
    public let values: [Float]

    public init(size: Int, values: [Float], title: String? = nil) {
        precondition(values.count == size * size * size * 3)
        self.size = size
        self.values = values
        self.title = title
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case noSize
        case badSize(Int)
        case wrongCount(expected: Int, found: Int)
        case badLine(Int, String)
        case badDomain

        public var errorDescription: String? {
            switch self {
            case .noSize: return "Not a .cube LUT (no LUT_3D_SIZE or LUT_1D_SIZE)."
            case .badSize(let n): return "LUT size \(n) isn't supported (3D: 2–\(CubeLUT.maxSize), 1D: 2–65536)."
            case .wrongCount(let e, let f): return "The LUT should have \(e) entries but has \(f)."
            case .badLine(let n, let text): return "Line \(n) isn't a LUT entry: \(text)"
            case .badDomain: return "The LUT's input range (DOMAIN_MIN/MAX) is empty."
            }
        }
    }

    public static func read(_ url: URL) throws -> CubeLUT {
        var lut = try parse(String(contentsOf: url, encoding: .utf8))
        if lut.title == nil { lut.title = url.deletingPathExtension().lastPathComponent }
        return lut
    }

    /// Reads .cube text: TITLE, LUT_3D_SIZE / LUT_1D_SIZE, DOMAIN_MIN / DOMAIN_MAX,
    /// LUT_3D_INPUT_RANGE / LUT_1D_INPUT_RANGE, # comments; other keywords are skipped.
    public static func parse(_ text: String) throws -> CubeLUT {
        var title: String?
        var size3 = 0, size1 = 0
        var domainMin = [0.0, 0, 0], domainMax = [1.0, 1, 1]
        var values: [Float] = []
        var lineNumber = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNumber += 1
            var line = Substring(raw)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            line = line.drop { $0 == " " || $0 == "\t" }
            guard let first = line.first else { continue }
            if first.isNumber || first == "-" || first == "+" || first == "." {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                let nums = parts.compactMap { Float($0) }
                guard parts.count == 3, nums.count == 3, nums.allSatisfy(\.isFinite) else {
                    throw ParseError.badLine(lineNumber, String(line.prefix(60)))
                }
                values += nums
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let key = parts[0].uppercased()
            let args = parts.dropFirst().compactMap { Double($0) }
            switch key {
            case "TITLE":
                let rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                title = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                guard let n = args.first.map(Int.init) else { throw ParseError.badLine(lineNumber, String(line)) }
                size3 = n
            case "LUT_1D_SIZE":
                guard let n = args.first.map(Int.init) else { throw ParseError.badLine(lineNumber, String(line)) }
                size1 = n
            case "DOMAIN_MIN":
                guard args.count == 3 else { throw ParseError.badLine(lineNumber, String(line)) }
                domainMin = args
            case "DOMAIN_MAX":
                guard args.count == 3 else { throw ParseError.badLine(lineNumber, String(line)) }
                domainMax = args
            case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                guard args.count == 2 else { throw ParseError.badLine(lineNumber, String(line)) }
                domainMin = [args[0], args[0], args[0]]
                domainMax = [args[1], args[1], args[1]]
            default:
                continue
            }
        }
        guard (0..<3).allSatisfy({ domainMax[$0] > domainMin[$0] }) else { throw ParseError.badDomain }
        let unitDomain = domainMin == [0, 0, 0] && domainMax == [1, 1, 1]

        if size3 > 0 {
            guard (2...maxSize).contains(size3) else { throw ParseError.badSize(size3) }
            let expected = size3 * size3 * size3
            guard values.count == expected * 3 else { throw ParseError.wrongCount(expected: expected, found: values.count / 3) }
            let lut = CubeLUT(size: size3, values: values, title: title)
            if unitDomain { return lut }
            // Resample onto 0–1 inputs: each grid point looks up where it falls in the file's range.
            return baked(size: size3, title: title) { rgb in
                lut.sample((0..<3).map { (rgb[$0] - domainMin[$0]) / (domainMax[$0] - domainMin[$0]) })
            }
        }
        if size1 > 0 {
            guard (2...65536).contains(size1) else { throw ParseError.badSize(size1) }
            guard values.count == size1 * 3 else { throw ParseError.wrongCount(expected: size1, found: values.count / 3) }
            return baked(size: bakedSize, title: title) { rgb in
                (0..<3).map { ch in
                    let t = (rgb[ch] - domainMin[ch]) / (domainMax[ch] - domainMin[ch])
                    let pos = min(max(t, 0), 1) * Double(size1 - 1)
                    let i = min(Int(pos), size1 - 2)
                    let f = pos - Double(i)
                    return Double(values[i * 3 + ch]) * (1 - f) + Double(values[(i + 1) * 3 + ch]) * f
                }
            }
        }
        throw ParseError.noSize
    }

    /// A LUT made by evaluating `transform` at each grid point.
    public static func baked(size: Int, title: String? = nil, _ transform: ([Double]) -> [Double]) -> CubeLUT {
        var values = [Float]()
        values.reserveCapacity(size * size * size * 3)
        let step = 1 / Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    values += transform([Double(r) * step, Double(g) * step, Double(b) * step]).map(Float.init)
                }
            }
        }
        return CubeLUT(size: size, values: values, title: title)
    }

    /// Trilinear lookup, inputs clamped to 0–1 (what the GPU does with it).
    public func sample(_ rgb: [Double]) -> [Double] {
        let n = size - 1
        var i0 = [0, 0, 0], f = [0.0, 0, 0]
        for c in 0..<3 {
            let p = min(max(rgb[c], 0), 1) * Double(n)
            i0[c] = min(Int(p), n - 1)
            f[c] = p - Double(i0[c])
        }
        func at(_ r: Int, _ g: Int, _ b: Int, _ ch: Int) -> Double {
            Double(values[((b * size + g) * size + r) * 3 + ch])
        }
        return (0..<3).map { ch in
            var sum = 0.0
            for db in 0...1 {
                for dg in 0...1 {
                    for dr in 0...1 {
                        let w = (dr == 1 ? f[0] : 1 - f[0]) * (dg == 1 ? f[1] : 1 - f[1]) * (db == 1 ? f[2] : 1 - f[2])
                        if w > 0 { sum += w * at(i0[0] + dr, i0[1] + dg, i0[2] + db, ch) }
                    }
                }
            }
            return sum
        }
    }

    /// RGBA Float32 entries (alpha 1), the layout Core Image's colour cube filters take.
    public func rgbaData() -> Data {
        var out = [Float](repeating: 1, count: size * size * size * 4)
        for i in 0..<(size * size * size) {
            out[i * 4] = values[i * 3]
            out[i * 4 + 1] = values[i * 3 + 1]
            out[i * 4 + 2] = values[i * 3 + 2]
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
