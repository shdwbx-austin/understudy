import Foundation
import Testing
@testable import UnderstudyCore

struct NotchLCTests {
    @Test func putsTranscodesInANotchLCFolderNamedLikeTheSource() {
        let media = URL(fileURLWithPath: "/Show/objects/VideoFile/ME 1")
        let folder = NotchLC.defaultFolder(mediaFolder: media)
        #expect(folder.path == "/Show/objects/VideoFile/ME 1/NotchLC")
        #expect(NotchLC.outputURL(for: media.appendingPathComponent("PGM_0003.mp4"), in: folder).path
                == "/Show/objects/VideoFile/ME 1/NotchLC/PGM_0003.mov")
    }

    @Test func chosenFolderHasADeckSubfolder() {
        let out = URL(fileURLWithPath: "/Out")
        #expect(NotchLC.chosenFolder(out, deck: " ME 1/PGM ").path == "/Out/ME 1-PGM")
        #expect(NotchLC.chosenFolder(out, deck: "  ").path == "/Out/Deck")
    }

    @Test func onlyTakesAreTranscoded() {
        #expect(NotchLC.canTranscode(URL(fileURLWithPath: "/b/PGM_0003.MOV")))
        #expect(NotchLC.canTranscode(URL(fileURLWithPath: "/b/PGM_0003.mp4")))
        #expect(!NotchLC.canTranscode(URL(fileURLWithPath: "/b/NotchLC/PGM_0003.mov")))
        #expect(!NotchLC.canTranscode(URL(fileURLWithPath: "/b/notes.txt")))
    }

    @Test func escapesJavaScriptStrings() {
        #expect(NotchLC.jsString(#"/Volumes/Show "A"/x\y.mov"#) == #""/Volumes/Show \"A\"/x\\y.mov""#)
        #expect(NotchLC.jsString("a\nb") == #""a\nb""#)
        #expect(NotchLC.jsString("Café") == #""Caf\u00E9""#)
        #expect(NotchLC.jsString("🎬") == #""\uD83C\uDFAC""#)
    }

    @Test func scriptQueuesTheFileWithThePreset() {
        let s = NotchLC.script(source: "/a/in.mov", output: "/a/out.mov", preset: "/p/NotchLC.epr",
                               statusFile: "/t/status.txt", currentFile: "/t/current")
        #expect(s.contains(#"addFileToBatch("/a/in.mov", format, "/p/NotchLC.epr", "/a/out.mov")"#))
        #expect(s.contains(#"var format = "";"#))
        let f = NotchLC.script(source: "/a/in.mov", output: "/a/out.mov", format: "NotchLC",
                               statusFile: "/t/status.txt", currentFile: "/t/current")
        #expect(f.contains(#"var format = "NotchLC";"#))
        #expect(f.contains(#"addFileToBatch("/a/in.mov", format, "", "/a/out.mov")"#))
        #expect(s.contains(#"append("/t/status.txt", line)"#))
        #expect(s.contains(#"new File("/t/current")"#))
        #expect(s.contains("runBatch()"))
    }

    @Test func watcherRunsJobsFromTheInbox() {
        let w = NotchLC.watcherScript(inbox: "/t/inbox", heartbeat: "/t/heartbeat", cancelFile: "/t/cancel", currentFile: "/t/current")
        #expect(w.contains("app.scheduleTask("))
        #expect(w.contains(#"getFiles(\"*.jsx\")"#))
        #expect(w.contains(#"\"/t/inbox\""#))
        #expect(w.contains("$.evalFile(job)"))
        // Paths sit inside a string of script, so they're escaped twice.
        #expect(w.contains(#"\"/t/cancel\""#))
        #expect(w.contains("stopBatch()"))
        #expect(w.contains(#"writeln(\"stopped\")"#))
    }

    @Test func readsTheStatusFile() {
        #expect(NotchLC.status(fromFile: "") == .starting)
        #expect(NotchLC.status(fromFile: "queued\n") == .queued)
        #expect(NotchLC.status(fromFile: "queued\nprogress 42\n") == .encoding(0.42))
        #expect(NotchLC.status(fromFile: "queued\nprogress 1\n") == .encoding(0.01))
        #expect(NotchLC.status(fromFile: "queued\nprogress 100\ndone\n") == .done)
        #expect(NotchLC.status(fromFile: "queued\nprogress 10\nstopped\n") == .stopped)
        #expect(NotchLC.status(fromFile: "failed Media Encoder: Failed!\n") == .failed("Media Encoder: Failed!"))
        // A late progress or failure line never undoes a finished encode.
        #expect(NotchLC.status(fromFile: "done\nprogress 99\nfailed x\n") == .done)
        #expect(NotchLC.status(fromFile: "progress abc\n") == .starting)
    }
}
