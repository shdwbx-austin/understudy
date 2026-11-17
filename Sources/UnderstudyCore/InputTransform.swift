import Foundation

// MARK: - The choice

/// A playback feed's look in Understudy's viewer and NDI out: nothing (the default: pictures as
/// recorded), or a .cube LUT the user chose, e.g. to turn log footage into Rec.709. It's a
/// playback setting only: the deck, its outputs and its recordings are never changed.
public enum InputTransform: Hashable, Sendable, Codable {
    /// As recorded.
    case none
    /// A .cube file: absolute in memory, stored relative when it's inside the project.
    case lut(path: String)

    public var title: String {
        switch self {
        case .none: return "None"
        case .lut(let path): return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }

    public var lutPath: String? {
        if case .lut(let path) = self { return path }
        return nil
    }

    // {} for none, {"lut": "objects/LUT/Show.cube"}. Anything else (e.g. a built-in conversion
    // from a pre-release build) reads as none: nothing is converted that the user didn't choose.
    private enum CodingKeys: String, CodingKey { case lut }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try c.decodeIfPresent(String.self, forKey: .lut), !path.isEmpty {
            self = .lut(path: path)
        } else {
            self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: break
        case .lut(let path): try c.encode(path, forKey: .lut)
        }
    }
}

// MARK: - Playback settings

/// How Understudy plays recordings back (viewer and NDI out), saved in the project apart from the
/// deck list: nothing here reaches a deck.
public struct PlaybackLUTSettings: Codable, Equatable, Sendable {
    /// Playback LUT per feed: the feed's name (the deck's name as View and NDI show it, e.g.
    /// "ME 1", which is also its folder in objects/VideoFile/) → .cube path.
    public var luts: [String: String] = [:]

    public init(luts: [String: String] = [:]) { self.luts = luts }

    /// A deck's feed name: its name, or "Deck N" when it has none (as the viewer labels it).
    public static func feed(_ deck: DeckConfig) -> String {
        let name = deck.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Deck \(deck.id + 1)" : name
    }

    public func lut(feed: String) -> InputTransform {
        luts[feed].map { .lut(path: $0) } ?? .none
    }

    public mutating func setLUT(_ transform: InputTransform, feed: String) {
        luts[feed] = transform.lutPath
    }

    /// Settings and projects saved before Playback LUTs kept a LUT on each deck
    /// (`decks[].inputTransform`): read those into a playback setting. `decks` is the raw deck list.
    public init(migratingDecks decks: [LegacyDeck]) {
        for deck in decks {
            guard case .lut(let path)? = deck.inputTransform else { continue }
            luts[Self.feed(DeckConfig(id: deck.id, name: deck.name ?? "ME \(deck.id + 1)", host: ""))] = path
        }
    }

    /// Just enough of an old deck entry to find its LUT.
    public struct LegacyDeck: Decodable, Sendable {
        public let id: Int
        public let name: String?
        public let inputTransform: InputTransform?
    }

    /// The saved playback settings, or (none saved) whatever older deck entries carried.
    static func decode<K: CodingKey>(from c: KeyedDecodingContainer<K>, playback: K, decks: K) -> PlaybackLUTSettings {
        if let saved = try? c.decodeIfPresent(PlaybackLUTSettings.self, forKey: playback) { return saved }
        let legacy = (try? c.decodeIfPresent([FailableLegacyDeck].self, forKey: decks)) ?? []
        return PlaybackLUTSettings(migratingDecks: legacy.compactMap(\.deck))
    }

    private struct FailableLegacyDeck: Decodable {
        let deck: LegacyDeck?
        init(from decoder: Decoder) throws { deck = try? LegacyDeck(from: decoder) }
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
