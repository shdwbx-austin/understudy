import Testing
@testable import UnderstudyCore

struct FTPPathsTests {
    @Test func parsesNameListings() {
        #expect(FTPPaths.names(fromListing: "1\r\n2\r\n") == ["1", "2"])
        #expect(FTPPaths.names(fromListing: "./PGM_0001.mov\n/1/PGM take 2.mov\n.\n..\n\n") == ["PGM_0001.mov", "PGM take 2.mov"])
    }

    @Test func buildsEncodedURLs() {
        #expect(FTPPaths.url(host: "10.0.0.5", path: []) == "ftp://10.0.0.5/")
        #expect(FTPPaths.url(host: "10.0.0.5", path: ["1"], directory: true) == "ftp://10.0.0.5/1/")
        #expect(FTPPaths.url(host: "10.0.0.5", path: ["1", "PGM take 2.mov"]) == "ftp://10.0.0.5/1/PGM%20take%202.mov")
        #expect(FTPPaths.url(host: "127.0.0.1", port: 2121, path: ["a#b"]) == "ftp://127.0.0.1:2121/a%23b")
    }

    @Test func readsContentLength() {
        #expect(FTPPaths.contentLength(fromHeaders: "Last-Modified: x\r\nContent-Length: 123456789\r\nAccept-ranges: bytes\r\n") == 123_456_789)
        #expect(FTPPaths.contentLength(fromHeaders: "nothing") == nil)
    }

    @Test func safeFolderNames() {
        #expect(FTPPaths.safeFolderName("ME 1/PGM") == "ME 1_PGM")
        #expect(FTPPaths.safeFolderName("  ") == "Deck")
    }
}
