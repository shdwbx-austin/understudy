import Foundation

/// Where a take's frames sit on show timecode.
///
/// Built while recording by comparing the deck's own timecode with show LTC, so a take stays
/// usable when LTC drops out or jumps: the deck keeps recording, and the map records which
/// stretches of show code landed where in the clip.
///
/// Positions are seconds. LTC seconds = LTC frame index / LTC fps.
/// Deck seconds = deck timecode frame index / deck timecode fps.
public struct TakeMap: Codable, Equatable, Sendable {
    public struct Segment: Codable, Equatable, Sendable {
        /// Show code covered, half-open: [ltcStart, ltcEnd).
        public var ltcStart: Double
        public var ltcEnd: Double
        /// Deck seconds = LTC seconds + offset.
        public var offset: Double

        public init(ltcStart: Double, ltcEnd: Double, offset: Double) {
            self.ltcStart = ltcStart
            self.ltcEnd = ltcEnd
            self.offset = offset
        }

        public var deckStart: Double { ltcStart + offset }
        public var deckEnd: Double { ltcEnd + offset }
        public var isEmpty: Bool { ltcEnd <= ltcStart }
        public func contains(ltc: Double) -> Bool { ltc >= ltcStart && ltc < ltcEnd }
    }

    /// Non-overlapping, sorted by `ltcStart`.
    public private(set) var segments: [Segment]
    public var createdAt: Date
    /// Whether the deck's own timecode counted drop-frame while this take was recorded
    /// (nil in maps from older versions). Playback reads deck timecode the same way.
    public var deckDropFrame: Bool?

    public init(segments: [Segment] = [], createdAt: Date = Date()) {
        self.segments = []
        self.createdAt = createdAt
        for s in segments { insert(s) }
    }

    /// A clip that was stamped with show code (decks on external timecode): deck time equals show time.
    public static func identity(deckStart: Double, duration: Double) -> TakeMap {
        TakeMap(segments: [Segment(ltcStart: deckStart, ltcEnd: deckStart + duration, offset: 0)])
    }

    public var isEmpty: Bool { segments.isEmpty }

    public func segmentIndex(atLTC ltc: Double) -> Int? {
        segments.firstIndex { $0.contains(ltc: ltc) }
    }

    /// Where the deck should be for show code `ltc`, or nil if that code wasn't recorded.
    public func deckSeconds(atLTC ltc: Double) -> Double? {
        segmentIndex(atLTC: ltc).map { ltc + segments[$0].offset }
    }

    /// Deck time spanned by the whole map.
    public var deckRange: ClosedRange<Double>? {
        guard let lo = segments.map(\.deckStart).min(), let hi = segments.map(\.deckEnd).max() else { return nil }
        return lo...hi
    }

    /// Keeps only what falls inside deck time [start, end), i.e. one clip's frames.
    public func clipped(toDeck start: Double, _ end: Double) -> TakeMap {
        var out = TakeMap(createdAt: createdAt)
        out.deckDropFrame = deckDropFrame
        for s in segments {
            let piece = Segment(
                ltcStart: max(s.ltcStart, start - s.offset),
                ltcEnd: min(s.ltcEnd, end - s.offset),
                offset: s.offset
            )
            out.insert(piece)
        }
        return out
    }

    /// Adds `segment`. Where it overlaps code already mapped, the new segment wins: if the show
    /// rolled the same code twice during one take, the later performance is the one played back.
    public mutating func insert(_ segment: Segment) {
        guard !segment.isEmpty else { return }
        var kept: [Segment] = []
        for s in segments {
            guard s.ltcStart < segment.ltcEnd, s.ltcEnd > segment.ltcStart else {
                kept.append(s)
                continue
            }
            let before = Segment(ltcStart: s.ltcStart, ltcEnd: min(s.ltcEnd, segment.ltcStart), offset: s.offset)
            let after = Segment(ltcStart: max(s.ltcStart, segment.ltcEnd), ltcEnd: s.ltcEnd, offset: s.offset)
            if !before.isEmpty { kept.append(before) }
            if !after.isEmpty { kept.append(after) }
        }
        kept.append(segment)
        segments = kept.sorted { $0.ltcStart < $1.ltcStart }
    }
}

/// Builds a `TakeMap` from paired readings taken while a deck records:
/// show code (LTC seconds) and the deck's own timecode (deck seconds) at the same instant.
///
/// Readings with a steady offset extend the current segment, through LTC gaps too. A changed
/// offset (show code jumped, re-rolled, or drifted) starts a new segment once it's confirmed by
/// several readings, so one late network reply can't split a take.
public struct TakeMapBuilder: Sendable {
    /// Largest disagreement between a reading and the current segment, in seconds.
    public var tolerance: Double
    /// Agreeing readings needed before a changed offset starts a new segment.
    public var confirmReadings: Int

    private struct Run: Sendable {
        var ltcStart: Double
        var ltcEnd: Double
        var offsetSum: Double
        var count: Int

        init(ltc: Double, offset: Double) {
            ltcStart = ltc
            ltcEnd = ltc
            offsetSum = offset
            count = 1
        }

        /// Continue a saved segment as if its readings were still here.
        init(_ s: TakeMap.Segment, weight: Int) {
            ltcStart = s.ltcStart
            ltcEnd = s.ltcEnd
            offsetSum = s.offset * Double(weight)
            count = weight
        }

        var offset: Double { offsetSum / Double(count) }

        mutating func add(ltc: Double, offset: Double) {
            ltcStart = min(ltcStart, ltc)
            ltcEnd = max(ltcEnd, ltc)
            offsetSum += offset
            count += 1
        }

        var segment: TakeMap.Segment { .init(ltcStart: ltcStart, ltcEnd: ltcEnd, offset: offset) }
    }

    private var committed: TakeMap
    private var current: Run?
    /// Stamped onto the map (see `TakeMap.deckDropFrame`).
    public var deckDropFrame: Bool?
    private var candidates: [(ltc: Double, offset: Double)] = []

    /// Code that resumes within this time of the previous run is treated as continuous
    /// (a mid-run offset change), so the two stretches meet with no gap.
    public var joinGap: Double = 0.5

    /// - Parameter map: a partial map to continue, e.g. one saved before the app restarted mid-take.
    ///   The most recently recorded segment is reopened, so if show code still lines up with the
    ///   deck after the restart, the map carries straight across the downtime.
    public init(resuming map: TakeMap? = nil, tolerance: Double = 0.05, confirmReadings: Int = 3) {
        self.tolerance = tolerance
        self.confirmReadings = confirmReadings
        deckDropFrame = map?.deckDropFrame
        var base = map ?? TakeMap()
        if let latest = base.segments.max(by: { $0.deckEnd < $1.deckEnd }) {
            base = TakeMap(segments: base.segments.filter { $0 != latest }, createdAt: base.createdAt)
            current = Run(latest, weight: 50)
        }
        committed = base
    }

    public mutating func add(ltc: Double, deck: Double) {
        let offset = deck - ltc
        guard var run = current else {
            current = Run(ltc: ltc, offset: offset)
            return
        }
        if abs(offset - run.offset) <= tolerance {
            run.add(ltc: ltc, offset: offset)
            current = run
            candidates.removeAll()
            return
        }
        if let first = candidates.first, abs(offset - first.offset) > tolerance {
            candidates.removeAll()
        }
        candidates.append((ltc, offset))
        guard candidates.count >= confirmReadings else { return }
        if candidates[0].ltc >= run.ltcEnd, candidates[0].ltc - run.ltcEnd <= joinGap {
            run.ltcEnd = candidates[0].ltc
        }
        committed.insert(run.segment)
        var next = Run(ltc: candidates[0].ltc, offset: candidates[0].offset)
        for c in candidates.dropFirst() { next.add(ltc: c.ltc, offset: c.offset) }
        current = next
        candidates.removeAll()
    }

    public var map: TakeMap {
        var m = committed
        if let run = current { m.insert(run.segment) }
        if let deckDropFrame { m.deckDropFrame = deckDropFrame }
        return m
    }
}
