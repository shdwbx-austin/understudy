import Foundation

/// Which file on this Mac is a deck's take. Decks reuse clip names (a formatted card starts again
/// at _0001), so the backup folder can hold several files with the take's name in different day
/// folders; the name alone isn't enough.
public enum TakeFileLookup {
    public struct Candidate: Equatable, Sendable {
        public var path: String
        public var modified: Date
        /// The folder the file sits in (a deck's folder in the backup or the project).
        public var folder: String
        /// The day folder above it in the backup (2026-11-17), if there is one.
        public var day: String?
        public var inProject: Bool

        public init(path: String, modified: Date, folder: String, day: String? = nil, inProject: Bool = false) {
            self.path = path
            self.modified = modified
            self.folder = folder
            self.day = day
            self.inProject = inProject
        }
    }

    /// The copy to play: in this deck's folder if any is (else any), the newest; on a tie a
    /// project copy wins (copying keeps the date, so it's the same recording).
    public static func best(_ candidates: [Candidate], deck: String) -> Candidate? {
        let names = Set([FTPPaths.safeFolderName(deck), folderName(deck)].map { $0.lowercased() })
        let mine = candidates.filter { names.contains($0.folder.lowercased()) }
        let pool = mine.isEmpty ? candidates : mine
        return pool.max { a, b in
            if abs(a.modified.timeIntervalSince(b.modified)) >= 2 { return a.modified < b.modified }
            return !a.inProject && b.inProject
        }
    }

    /// A deck's folder name inside the project (as `ProjectManager` makes it).
    public static func folderName(_ deck: String) -> String {
        let t = deck.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        return t.isEmpty ? "Deck" : t
    }

    /// Whether a copy of `size` bytes fits with `available` free, keeping a margin for the system.
    public static func fits(size: Int64, available: Int64, margin: Int64 = 10_000_000_000) -> Bool {
        size + margin <= available
    }
}
