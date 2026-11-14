import Foundation

/// Helpers for pulling clips off a HyperDeck's FTP server (port 21, no login).
public enum FTPPaths {
    /// Names from a name-only directory listing (`NLST`, curl `--list-only`): one per line,
    /// sometimes with a leading path. "." and ".." are dropped.
    public static func names(fromListing listing: String) -> [String] {
        listing.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let name = line.split(separator: "/").last.map(String.init) ?? line
            return name == "." || name == ".." ? nil : name
        }
    }

    /// An ftp:// URL for `path` components on `host`, each component percent-encoded
    /// (clip names can contain spaces). A trailing slash asks for a directory listing.
    public static func url(host: String, port: Int = 21, path: [String], directory: Bool = false) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;?#"))
        let encoded = path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        let portPart = port == 21 ? "" : ":\(port)"
        let joined = encoded.joined(separator: "/")
        return "ftp://\(host)\(portPart)/\(joined)\(directory && !joined.isEmpty ? "/" : "")"
    }

    /// `Content-Length` from curl's FTP header output (`curl -sI ftp://…`).
    public static func contentLength(fromHeaders headers: String) -> Int64? {
        for line in headers.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int64(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// A folder-safe version of a deck name.
    public static func safeFolderName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { bad.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Deck" : cleaned
    }
}
