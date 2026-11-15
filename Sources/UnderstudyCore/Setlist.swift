import Foundation

/// A named set: song names in playing order. Names, not ids, so a set survives re-importing a
/// corrected song list.
public struct Setlist: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var songs: [String]

    public init(id: UUID = UUID(), name: String, songs: [String] = []) {
        self.id = id
        self.name = name
        self.songs = songs
    }
}

extension SongLibrary {
    /// Puts exactly the setlist's songs on the set, in its order; everything else to the library.
    /// Names the library doesn't have are skipped.
    public static func applying(_ setlist: Setlist, to songs: [Song], rate: FrameRate) -> [Song] {
        var pool = songs.map { song -> Song in var s = song; s.inSet = false; return s }
        var set: [Song] = []
        for name in setlist.songs {
            guard let i = pool.firstIndex(where: { $0.name == name && !$0.inSet }) else { continue }
            pool[i].inSet = true
            set.append(pool[i])
        }
        return set + arranged(pool.filter { !$0.inSet }, rate: rate)
    }
}

/// The order songs were actually played in a recorded take, read from its take map: each song's
/// stretch of show code is looked up in the map, and the songs found are sorted by where in the
/// recording they started.
public enum RunningOrder {
    public struct Placed: Equatable, Sendable {
        public var id: UUID
        /// Seconds into the take where the song's code first appears.
        public var takeTime: Double
        /// Seconds of the song's code the take recorded.
        public var recorded: Double
    }

    /// `songs` are (id, show start seconds, length seconds). A song counts as played when the take
    /// recorded at least `minimum` seconds of it (or half of it, for a short song).
    public static func placed(songs: [(id: UUID, start: Double, length: Double)], in map: TakeMap,
                              minimum: Double = 10) -> [Placed] {
        var out: [Placed] = []
        for song in songs where song.length > 0 {
            let end = song.start + song.length
            var recorded = 0.0
            var first = Double.infinity
            for segment in map.segments {
                let lo = max(segment.ltcStart, song.start)
                let hi = min(segment.ltcEnd, end)
                guard hi > lo else { continue }
                recorded += hi - lo
                first = min(first, lo + segment.offset)
            }
            if recorded >= min(minimum, song.length / 2) {
                out.append(Placed(id: song.id, takeTime: first, recorded: recorded))
            }
        }
        return out.sorted { $0.takeTime < $1.takeTime }
    }
}
