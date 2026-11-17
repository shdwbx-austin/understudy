# NotchLC transcoding on macOS: feasibility

Goal: turn recorded takes (HyperDeck backups, project media, and later the
internal recorder's files) into NotchLC `.mov` test clips for disguise and
other media servers, from inside Understudy on a Mac.

Short answer: **there is no free, standalone, command-line NotchLC encoder for
macOS.** The only lawful way to encode NotchLC on a Mac today is Notch's free
plugin for Adobe Media Encoder / Premiere / After Effects. Understudy could
drive Media Encoder with it, but only after the plugin is installed, and the
way to drive it from the command line isn't officially supported. Everything
else is Windows-only, commercially licensed, or both.

Researched 2026-11-16.

## Options

| Option | Runs on macOS | Encoder included | Licence / cost | Automatable from Understudy |
|---|---|---|---|---|
| FFmpeg | yes | **no**, it only has a decoder (`notchlc`, added 2020) | LGPL/GPL | n/a |
| NotchLC SDK | yes (Metal implementation) | yes | commercial licence; contact Notch sales; price not published | yes, but can't ship in this public repo |
| NotchLC Advanced Pipeline Tools (`NotchLCProcessor.exe`) | **no**, Windows only | yes | node licences, $275/yr each, at least 5; CodeMeter runtime and licence server | on a Windows helper only |
| Notch Builder CLI (`-transcode`, `-codec nclc`) | **no**, Builder is Windows only | yes | needs a Notch licence | on a Windows helper only |
| Notch plugin for Adobe AME / Premiere / AE | yes, macOS 13+ (Intel and Apple Silicon), plugin 1.4.3 | yes | plugin is free; Adobe Creative Cloud subscription needed | partly: AME scripting (see below) |
| TouchDesigner Movie File Out TOP | unclear on macOS | yes on Windows | TD licence | no, needs the TD app running a network |
| PIXERA transcoder | no, Windows | yes | PIXERA licence | no |
| Write our own encoder | yes | — | no published bitstream spec; Notch has said it has no plans for one | not pursued (see below) |

### FFmpeg

FFmpeg only decodes NotchLC. On the Notch forum, Notch staff said an FFmpeg
encoder would mean open-sourcing NotchLC or keeping a closed-source FFmpeg
branch, and that they don't have the bandwidth for either. The decoder is
still useful: it can check that an encoded file decodes and has the right
frame count.

### NotchLC SDK

"A fully documented SDK available under a commercial license", with DirectX,
Metal and OpenGL implementations. You get it by contacting Notch
(notchlc.notch.one, support/sales form). This is the cleanest technical route,
because Understudy could encode in-process with progress and cancel. But the
licence terms aren't public, Understudy is a public repo, and the SDK can't be
committed here. The most it could become is an optional library that the user
installs and Understudy loads if it's there.

### Advanced Pipeline Tools / Builder CLI

`NotchLCProcessor.exe -options input output.mov` encodes images or video to
NotchLC QuickTime with `-quality 0–1000`, `-fps`, `-alpha` and so on. It is
Windows only and licensed per node through CodeMeter. Builder's `-transcode`
is also Windows only. Either one fits a **Windows helper**: Understudy writes
a ProRes mezzanine to a shared folder, and a Windows box (a spare PC, or an
off-show media server) runs the tool. That means a licence purchase and a
second machine.

### Adobe Media Encoder + Notch plugin (the only macOS route)

- The plugin is free from notch.one/downloads. It needs macOS 13+ and installs
  into Adobe's shared plug-ins folder, which is a system-wide install.
- Adobe Media Encoder 2026 and 2027 are already installed on this Mac. **The
  Notch plugin is not** (`/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore`
  has no Notch bundle).
- Driving it: AME runs ExtendScript with
  `"…/Adobe Media Encoder 2027.app/Contents/MacOS/Adobe Media Encoder 2027" --console es.processFile /abs/script.jsx`.
  The script calls `app.getFrontend().addFileToBatch(src, "", preset.epr, out)`
  and `app.getEncoderHost().runBatch()`. Per-item events (`onEncodeProgress`,
  `onEncodeFinished`) and `stopBatch()` are in the community-maintained
  scripting reference. However, the command-line launch isn't covered by
  Adobe's docs, a forum post linked to Adobe calls it "not a recommended
  approach", and users report scripts that silently leave the queue empty.
  Progress would have to be written to a file from the script, and the only
  way to cancel is to stop the whole batch.
- Fallback that needs no scripting: an AME **watch folder** with a NotchLC
  preset. Understudy copies the take in and watches the output folder. It's
  reliable but has no progress or cancel, and the user sets it up once in AME.
- Timecode and frame rate: AME normally carries the QuickTime timecode track
  and frame rate through. This needs checking with the plugin installed.

### Our own encoder: not pursued

NotchLC has no published spec, and Notch declined to publish one. Notch sells
encoding through the SDK and pipeline tools. Reverse engineering FFmpeg's
LGPL decoder into an encoder is possible in principle, but whether to do it is
a legal and business decision for ShdwBX, not a technical one. It would also
put an unofficial encoder in front of disguise's official decoder with no
reference encoder here to check conformance against.

## Recommendation

1. **Preferred (macOS, no purchase):** the user installs Notch's free Adobe
   plugin. Understudy then adds "Transcode to NotchLC…" per take, driving AME
   2026/2027 through `--console es.processFile`. It falls back to "open the
   take in AME with the NotchLC preset" if the scripted queue doesn't start.
   Before building this, make one manual NotchLC export in AME to confirm the
   plugin, timecode and frame rate. Verify output with a non-system FFmpeg
   build kept in a temp folder (`ffprobe -count_frames`, `ffmpeg -f null`).
2. **If Adobe is a no-go:** a Windows helper running `NotchLCProcessor.exe`
   (APT licence) or Builder `-transcode`. Understudy would export ProRes 422 HQ
   with timecode to a shared folder.
3. **Longer term:** licence the NotchLC SDK and load it as an optional,
   user-supplied library.

## What was built (option 1)

*Record › Transcode a Take to NotchLC…* (see the README) drives Media Encoder 2026/2027 with
the Notch plugin. What testing turned up:

- **The format is "NotchLC (Metal)"** in Media Encoder's format list. It has no presets of its
  own, so `addFileToBatch(src, "NotchLC (Metal)", "", out)` uses the format's defaults. Understudy
  finds the format by name ("NotchLC"), or uses an `.epr` the user saved.
- **`--console es.processFile` only works when it starts Media Encoder.** While it's open, a
  second launch is ignored, and Media Encoder has no AppleScript dictionary. So the first launch
  runs a watcher (`app.scheduleTask`, every second) that runs job scripts dropped into a folder,
  touches a heartbeat file, and stops the queue when a cancel file appears.
- **Per-item events aren't per item.** Listeners added for one queued item also fire for later
  items. So every listener writes to the status file of the current job, and Understudy runs
  one job at a time. Stopping the queue sends no event, so the watcher writes "stopped" itself.
  Progress arrives as 0–100.
- **The plugin crashes Media Encoder on long output paths.** It's a stack buffer overflow in
  the plugin's `createMovieFile`, seen with a ~240-character path and fine at ~75. Encodes go to
  `$TMPDIR/understudy-nlc/<8 chars>.mov`.
- **No timecode track.** The plugin writes video (`nclc`, at the source's exact timescale:
  1001/30000 at 29.97) and an audio track, but no `tmcd`. Understudy copies the encode into
  place with AVFoundation, as a passthrough (macOS can't decode NotchLC, and doesn't need to),
  with the source's timecode sample added. Each track keeps its own timescale, because
  AVAssetWriter's default of 1/600 s would turn 29.97 into 29.975.
- **Notch's importer can't read NotchLC under a non-ASCII path.** Media Encoder silently gets
  nothing, so a decode makes black 720×480 frames. This affects reading NotchLC back in Adobe
  apps, not encoding (sources go through Adobe's own importers, and the output is a temp path).
  The harness decodes from a plain path.
- **Killing Media Encoder** (SIGTERM) brings up Adobe's crash reporter. Quit it with a script
  (`app.quit()`).

Verified by `scripts/notchlc-harness.sh` with 25, 29.97 and 59.94 clips (one under a non-ASCII
path, the output under a long Dropbox-like path): codec, frame count, rate and timecode of the
output, a decode back through Notch's importer (NotchLC → H.264 in Media Encoder) with every
frame's burned-in counter in order, and Cancel. FFmpeg's NotchLC decoder wasn't used, because no FFmpeg is installed
on the build Mac.

## Sources

- NotchLC overview and SDK licensing: https://notchlc.notch.one/
- Notch downloads (Adobe plugin 1.4.3, macOS 13+; Notch app Windows only): https://notch.one/downloads
- Advanced Pipeline Tools (Windows only, licensing): https://manual.notch.one/2026.1/en/docs/reference/notchlc/advanced-pipeline-tools/
- NotchLC Processor CLI: https://manual.notch.one/2026.1/en/docs/reference/notchlc/advanced-pipeline-tools/notchlc-processor/
- Notch forum, command-line encoder / FFmpeg / spec: https://forum.notch.one/t/command-line-encode-utility/851
- FFmpeg NotchLC decoder commit: https://lists.mplayerhq.hu/pipermail/ffmpeg-cvslog/2020-May/122205.html
- NotchLC on macOS (Metal): https://www.redsharknews.com/production/item/7016-notchlc-gpu-powered-intermediary-and-playback-codec-now-supports-macos
- AME scripting reference: https://ame-scripting.docsforadobe.dev/reference/index.html
- AME command-line scripting thread: https://community.adobe.com/t5/adobe-media-encoder-discussions/current-media-encoder-automation-from-command-line-information/td-p/13110808
- TouchDesigner Movie File Out TOP: https://derivative.ca/UserGuide/Movie_File_Out_TOP
- PIXERA NotchLC encoding: https://pixera.helpjuice.com/pixera-251/notch-lc-encoding
