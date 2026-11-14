import Foundation

/// A small brightness picture (0…1 per cell) of one deck's image, from the confidence monitor.
public struct LumaGrid: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    public var mean: Float { values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count) }

    /// Share of cells brighter than `level`.
    public func fraction(above level: Float) -> Float {
        values.isEmpty ? 0 : Float(values.filter { $0 > level }.count) / Float(values.count)
    }

    /// Largest single-cell change from another grid (catches small movement in a static frame).
    public func maxDifference(from other: LumaGrid) -> Float {
        guard other.values.count == values.count, !values.isEmpty else { return 1 }
        var m: Float = 0
        for i in values.indices { m = max(m, abs(values[i] - other.values[i])) }
        return m
    }

    /// Mean absolute difference from another grid of the same size (0 = identical).
    public func difference(from other: LumaGrid) -> Float {
        guard other.values.count == values.count, !values.isEmpty else { return 1 }
        var sum: Float = 0
        for i in values.indices { sum += abs(values[i] - other.values[i]) }
        return sum / Float(values.count)
    }
}

/// What a deck's picture looks like.
public enum PictureState: Equatable, Sendable {
    case picture
    /// Near black for a while (not a quick fade through black).
    case black
    /// Not changing for a while. Only a fault when the deck should be moving (playing).
    case still
    /// No frames from the capture device.
    case noFeed
}

public struct PictureCheckSettings: Codable, Equatable, Sendable {
    /// Seconds of black before it's reported.
    public var blackSeconds: Double = 2
    /// Seconds without change before it's reported.
    public var stillSeconds: Double = 3
    /// Seconds without frames before the feed counts as lost.
    public var feedTimeout: Double = 2
    /// Mean brightness under which a picture can count as black.
    public var blackLevel: Float = 0.06
    /// Mean change between checks under which a picture counts as not moving
    /// (above capture-device noise, below real motion).
    public var stillLevel: Float = 0.004

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PictureCheckSettings()
        blackSeconds = (try? c.decodeIfPresent(Double.self, forKey: .blackSeconds)) ?? d.blackSeconds
        stillSeconds = (try? c.decodeIfPresent(Double.self, forKey: .stillSeconds)) ?? d.stillSeconds
        feedTimeout = (try? c.decodeIfPresent(Double.self, forKey: .feedTimeout)) ?? d.feedTimeout
        blackLevel = (try? c.decodeIfPresent(Float.self, forKey: .blackLevel)) ?? d.blackLevel
        stillLevel = (try? c.decodeIfPresent(Float.self, forKey: .stillLevel)) ?? d.stillLevel
    }
}

/// Tracks one deck's picture over time. Fed a few times a second; brief fades and pauses don't trip it.
public struct PictureChecker: Sendable {
    public var settings: PictureCheckSettings
    private var previous: LumaGrid?
    private var blackSince: Double?
    private var stillSince: Double?
    private var lastFrame: Double?

    public init(settings: PictureCheckSettings = PictureCheckSettings()) {
        self.settings = settings
    }

    public mutating func reset() {
        previous = nil
        blackSince = nil
        stillSince = nil
        lastFrame = nil
    }

    /// Takes a new frame and returns the state at `time`.
    @discardableResult
    public mutating func update(_ grid: LumaGrid, at time: Double) -> PictureState {
        lastFrame = time
        // Black: dark overall and essentially nothing bright (a dark scene with highlights isn't black).
        let isBlack = grid.mean < settings.blackLevel && grid.fraction(above: settings.blackLevel * 3) < 0.01
        blackSince = isBlack ? (blackSince ?? time) : nil
        // Still = no change on average AND nowhere in particular: a wide shot with a small
        // moving performer changes a few cells a lot and must not read as frozen.
        if let previous, !isBlack, grid.difference(from: previous) < settings.stillLevel,
           grid.maxDifference(from: previous) < 0.08 {
            stillSince = stillSince ?? time
        } else {
            stillSince = nil
        }
        previous = grid
        return state(at: time)
    }

    public func state(at time: Double) -> PictureState {
        guard let lastFrame, time - lastFrame < settings.feedTimeout else { return .noFeed }
        if let blackSince, time - blackSince >= settings.blackSeconds { return .black }
        if let stillSince, time - stillSince >= settings.stillSeconds { return .still }
        return .picture
    }
}

/// Where each deck sits in the captured image.
public enum ConfidenceLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A quad-split multiviewer: four decks, one per quarter.
    case quad
    /// The whole image is one deck.
    case single

    public var id: String { rawValue }

    /// Quarters in reading order: 0 top left, 1 top right, 2 bottom left, 3 bottom right.
    public static let quadrantNames = ["Top left", "Top right", "Bottom left", "Bottom right"]

    /// The part of the image (normalised, origin top left) showing `quadrant`.
    public static func rect(quadrant: Int) -> (x: Double, y: Double, width: Double, height: Double) {
        let q = max(0, min(3, quadrant))
        return (Double(q % 2) * 0.5, Double(q / 2) * 0.5, 0.5, 0.5)
    }
}
