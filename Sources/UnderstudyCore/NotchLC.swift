import Foundation

/// NotchLC transcoding through Adobe Media Encoder and Notch's free NotchLC plugin, the only way
/// to encode NotchLC on a Mac (see docs/NOTCHLC.md). This file is the logic that doesn't need AME:
/// output naming, the ExtendScript that queues one file, and reading the status it writes back.
public enum NotchLC {
    /// Transcodes go in a folder of this name beside the media they came from.
    public static let folderName = "NotchLC"

    /// Where a transcode goes by default: a NotchLC folder in `mediaFolder` (the deck's folder of
    /// project media, or the folder the source is in).
    public static func defaultFolder(mediaFolder: URL) -> URL {
        mediaFolder.appendingPathComponent(folderName, isDirectory: true)
    }

    /// In a chosen folder, each deck gets its own subfolder, so takes with the same name on
    /// different decks don't collide.
    public static func chosenFolder(_ folder: URL, deck: String) -> URL {
        let t = deck.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        return folder.appendingPathComponent(t.isEmpty ? "Deck" : t, isDirectory: true)
    }

    /// The transcode of `source` in `folder`, named like the source: `PGM_0003.mp4` → `PGM_0003.mov`.
    public static func outputURL(for source: URL, in folder: URL) -> URL {
        folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".mov")
    }

    /// A take's files are QuickTime, MP4 or MXF from a deck or the recorder. Anything already in a
    /// NotchLC folder is a transcode, not a take.
    public static func canTranscode(_ url: URL) -> Bool {
        guard ["mov", "mp4", "mxf"].contains(url.pathExtension.lowercased()) else { return false }
        return url.deletingLastPathComponent().lastPathComponent != folderName
    }

    // MARK: ExtendScript for Media Encoder

    /// A JavaScript string literal for `s` (ExtendScript is ES3, so only plain escapes).
    public static func jsString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 || scalar.value > 0x7E {
                    if scalar.value > 0xFFFF {
                        // Surrogate pair.
                        let v = scalar.value - 0x10000
                        out += String(format: "\\u%04X\\u%04X", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                    } else {
                        out += String(format: "\\u%04X", scalar.value)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// A job script: queues `source` with `format` (that format's default preset) or a `preset`
    /// file, and starts Media Encoder's queue. The watcher (below) runs it.
    ///
    /// Progress comes from Media Encoder's events, and those aren't reliably per item: listeners
    /// added for one item also fire for the next one. So every listener writes to whichever status
    /// file `currentFile` names (Understudy runs one transcode at a time and points it at that
    /// job before submitting), and only the job's own "queued" or setup failure goes straight to
    /// `statusFile`.
    public static func script(source: String, output: String, format: String = "", preset: String = "",
                              statusFile: String, currentFile: String) -> String {
        """
        // Written by Understudy: transcode one file to NotchLC.
        (function () {
            function append(path, line) {
                var f = new File(path);
                f.encoding = "UTF-8";
                f.lineFeed = "Unix";
                if (f.open("a")) { f.writeln(line); f.close(); }
            }
            function report(line) { append(\(jsString(statusFile)), line); }
            function reportCurrent(line) {
                var c = new File(\(jsString(currentFile)));
                c.encoding = "UTF-8";
                if (!c.open("r")) { return; }
                var path = c.read();
                c.close();
                if (path) { append(path, line); }
            }
            try {
                var frontend = app.getFrontend();
                var host = app.getEncoderHost();
                if (!frontend || !host) { report("failed Media Encoder's scripting isn't available"); return; }
                if (host.isBatchRunning && host.isBatchRunning()) {
                    report("failed Media Encoder is busy with its own queue: let it finish, then try again");
                    return;
                }
                // The format by name, or the first one containing it ("NotchLC" finds "NotchLC (Metal)").
                var format = \(jsString(format));
                if (format) {
                    var formats = host.getFormatList(), exact = false, match = "";
                    for (var i = 0; i < formats.length; i++) {
                        if (formats[i] === format) { exact = true; }
                        if (!match && String(formats[i]).indexOf(format) >= 0) { match = String(formats[i]); }
                    }
                    if (!exact) {
                        if (!match) { report("failed Media Encoder has no " + format + " format: install Notch's NotchLC plugin, then quit and reopen Media Encoder"); return; }
                        format = match;
                    }
                }
                var item = frontend.addFileToBatch(\(jsString(source)), format, \(jsString(preset)), \(jsString(output)));
                if (!item) { report("failed Media Encoder couldn't queue the file (check the preset, and that the NotchLC plugin is installed)"); return; }
                item.addEventListener("onEncodeProgress", function (e) { reportCurrent("progress " + e.result); }, false);
                item.addEventListener("onEncodeFinished", function (e) {
                    var r = String(e.result);
                    if (r.indexOf("Done") === 0) { reportCurrent("done"); }
                    else if (r.indexOf("Stop") === 0) { reportCurrent("stopped"); }
                    else { reportCurrent("failed Media Encoder: " + r); }
                }, false);
                item.addEventListener("onError", function (e) { reportCurrent("failed Media Encoder: " + e.result); }, false);
                report("queued");
                host.runBatch();
            } catch (err) {
                report("failed " + err);
            }
        })();
        """
    }

    /// The script Media Encoder runs once, when Understudy starts it. A second
    /// `--console es.processFile` while Media Encoder is open is ignored, so this installs a task
    /// that runs every second: it touches `heartbeat` (so Understudy can tell it's alive), stops
    /// the queue if `cancelFile` exists (deleting it, and writing "stopped" to the status file
    /// `currentFile` names, as stopping sends no event), and runs any `*.jsx` dropped into `inbox`
    /// (renamed to `.running` first, deleted after).
    public static func watcherScript(inbox: String, heartbeat: String, cancelFile: String, currentFile: String) -> String {
        let poll = """
        (function () {
            var hb = new File(\(jsString(heartbeat)));
            if (hb.open("w")) { hb.write(String(new Date().getTime())); hb.close(); }
            var cancel = new File(\(jsString(cancelFile)));
            if (cancel.exists) {
                cancel.remove();
                try { app.getEncoderHost().stopBatch(); } catch (e1) {}
                // Stopping sends no event, so say so for the current job.
                var c = new File(\(jsString(currentFile)));
                if (c.open("r")) {
                    var path = c.read();
                    c.close();
                    var st = new File(path);
                    st.lineFeed = "Unix";
                    if (path && st.open("a")) { st.writeln("stopped"); st.close(); }
                }
            }
            var jobs = new Folder(\(jsString(inbox))).getFiles("*.jsx");
            for (var i = 0; i < jobs.length; i++) {
                var job = jobs[i];
                var name = job.name.replace(/\\.jsx$/, ".running");
                if (!job.rename(name)) { continue; }
                try { $.evalFile(job); } catch (e2) {}
                job.remove();
            }
        })();
        """
        return """
        // Written by Understudy: watch for transcode jobs while Media Encoder is open.
        app.scheduleTask(\(jsString(poll)), 1000, true);
        """
    }

    /// The watcher touched its heartbeat this recently, so Media Encoder is open and listening.
    public static let heartbeatFresh: TimeInterval = 5

    // MARK: Status written back by the script

    public enum Status: Equatable, Sendable {
        /// Nothing written yet: Media Encoder is still starting.
        case starting
        case queued
        /// 0…1.
        case encoding(Double)
        case done
        case stopped
        case failed(String)

        public var isFinal: Bool {
            switch self {
            case .done, .stopped, .failed: return true
            default: return false
            }
        }
    }

    /// The status a status file's contents describe: its last meaningful line. Progress arrives as
    /// a percentage (Media Encoder's per-item event) and is reported as 0…1.
    public static func status(fromFile text: String) -> Status {
        var status = Status.starting
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "queued" {
                if !status.isFinal { status = .queued }
            } else if line.hasPrefix("progress ") {
                guard !status.isFinal, let v = Double(line.dropFirst("progress ".count)) else { continue }
                status = .encoding(min(1, max(0, v / 100)))
            } else if line == "done" {
                status = .done
            } else if line == "stopped" {
                if status != .done { status = .stopped }
            } else if line.hasPrefix("failed") {
                if status != .done {
                    let why = line.dropFirst("failed".count).trimmingCharacters(in: .whitespaces)
                    status = .failed(why.isEmpty ? "Media Encoder failed" : why)
                }
            }
        }
        return status
    }
}
