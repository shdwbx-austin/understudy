# understudy

**Stands in for the cameras between run-throughs.**

Record four broadcast MEs on HyperDecks, then play them back into the disguise capture inputs locked to show timecode — so you can program against real SDI between run-throughs, with no files to copy and no transcoding.

Shdwbx · Design and Creative Support

---

## What it does

| Mode | Decks | disguise sees |
| --- | --- | --- |
| **STOP** `⌘1` | Stopped, disarmed, in preview | Live ME (passes through the deck) |
| **REC** `⌘2` | Recording from now until STOP | Live ME |
| **PLAY TC** `⌘3` | Chase show LTC from the selected take | Recorded ME, in sync with code |

After a run-through, hit **PLAY TC**. The latest take is selected, and the decks follow code every time you roll it.

### Recording survives timecode failures

By default the decks record continuously from **REC** until **STOP**, stamped with their own clock. Show LTC doesn't start or stop anything. While they record, Understudy reads each deck's timecode ten times a second, pairs it with show LTC at that instant, and saves a timecode map for the take.

- **LTC drops out:** the decks keep recording. Code that never arrived just isn't in the map. If code comes back where it should be, the map carries straight across the gap.
- **LTC jumps** (per-song code, a re-roll): the map starts a new stretch. If the same code is rolled twice in one take, playback uses the later pass.
- **Short dropouts:** the show clock coasts (freewheels) for 2 s by default, so a glitch doesn't stop playback or re-park the decks. The header shows **FREEWHEEL · NO LTC** while it coasts.

Maps live in `~/Library/Application Support/Understudy/takemaps/`. The map in progress is saved every 5 s, so a crash mid-take loses only a few seconds of it.

If you'd rather have the decks record only while code runs and stamp clips with show code (v0.1.0 behaviour), choose **Settings › Recording › Only while show timecode runs**. A dropout then stops the recording. Takes without a map are played back from their clip timecode, so recordings made that way, or with 0.1.0, still work.

### Separate show and playback timecode inputs

To review against a local timecode source without repatching, turn on **Settings › Timecode input › Use a separate input for Play to code** and pick its device and channel. Stop and Record read **Show timecode**; Play to code reads **Playback timecode**. The header and footer say which is in use.

- Both inputs can be channels on one interface (the switch is instant) or on two interfaces (the input reopens).
- The playback source must carry the **same timecode values** as the show (e.g. a local playback of the show's timecode track), because takes are mapped against show code.
- Each input's rate is measured afresh when it's switched in, so chasing starts about 2 seconds after entering Play.

### Timecode rate is detected automatically

Understudy works out the show timecode rate from the incoming LTC and follows it, including drop-frame. It can tell 23.976 from 24 and 29.97 from 30, timing frames on the audio sample clock, within about 2 seconds of code. The header shows **AUTO 29.97 DF** (or whatever it found) and the measured rate.

- **Before the rate is known**, recording logs and playback wait. That's only the first couple of seconds of code after launch or after changing the audio input. Decks still record.
- **If the show switches to a different rate**, the new rate must hold for 2 seconds before Understudy follows it.
- **Takes stay valid across rates**, because take maps are stored in seconds.
- **A fixed rate** can be set under **Settings › LTC input › Show timecode rate**. The header then warns if incoming code doesn't match it.

### Playback

HyperDecks can't chase LTC natively. Understudy reads the show LTC itself and handles each deck in four steps:

1. When code starts or jumps, it looks the code up in the take's map and sends the deck to the matching frame and plays it in one go, aimed a few frames ahead to cover the deck's goto (about 20 ms) and start delay (its play offset). On a HyperDeck Studio 4K Pro the deck is in sync about 85 ms later; in Timeline mode, where the decks are already parked on the playhead, it rolls with the timeline.
2. It watches the deck's timecode ten times a second.
3. It re-parks the deck if it drifts out of tolerance, if code moves into a different recorded stretch, or if the deck stops by itself.
4. If the deck holds steadily half a frame or more off, it trims the deck's play offset so the next start lands closer.

**Fast pickup** is on by default (Settings › Chase). Turn it off to park decks pre-roll ahead and fire `play` once they've settled: slower to pick up, for decks that locate slowly.

## Timeline (rehearsing songs out of order)

Timeline mode (**⌘4**) makes Understudy the clock instead of incoming LTC. Open the timeline with **⌘T**.

1. **Import CSV…:** a song list, one song per row: a name, a start timecode, and optionally an end or a Duration (`m:ss`). With a header row, columns are found by name (e.g. `SONG, Duration, LTC Start Point`). Starts can be `H:MM:SS` or full timecode. Songs with a blank or `n/a` start are skipped and listed after import. A song without an end or duration runs to the next song's start. An alphabetical list is laid out in timecode order.
2. **Audio:** **Find audio…** and pick the folder with the show's audio. Files are matched to songs by name, including subfolders, ignoring track numbers, BPM and the like, and the result lists any set songs still without audio. Or drop a file on a song, or right-click › Choose Audio…. Audio plays from the song's start timecode, and its waveform appears on the timeline.
3. **Set:** imported songs form the **Library**. Add tonight's songs to the **Set** with **+**. Only the set plays, and **Remove** takes a song off it (it stays in the library). An alphabetical sheet lands in the library; a list in running order becomes the set directly. Re-importing a corrected sheet keeps your set, its order and any audio.
4. **Order:** drag songs in the set. The timeline plays them back to back in that order. A lead-in before each song (2 s by default) gives the decks time to park on its footage.
   - **Setlists:** the Setlist menu saves the set under a name and switches between saved sets. **Order Set by Latest Take** (in the same menu) puts the set in the order the songs played in that take, and **Auto-Order After Each Take** does it every time a take ends.
5. **Play:** space plays and pauses. Click, drag or swipe to move the playhead; while playing it keeps playing from there (audio stays quiet until you stop moving). ← → step one frame, ⇧← → one second, ⌥← → one song. While paused the decks seek to the frame under the playhead; while playing they chase it.
6. **Outputs:** Settings › Timeline output picks the device and channels for song audio. **LTC out** generates timecode that follows the timeline, so disguise (or anything else) can chase the reordered playlist too.
   - **Timecode in the audio:** audio files are scanned for LTC. A timecode channel is muted on the music output, left off the waveform, lines the audio up, and plays to LTC out in place of the generator. Turn either off per song (right-click › Play Timecode Channel) or for all songs (Settings › Timeline output › Use the track's own timecode).

**Recording names.** Settings › Recording › File name sets how decks name their recordings. The default is `{deck}_{artist}_{date}_{time}` (e.g. `ME_1_RKS_2026-11-15_2015_0001.mov`). Tokens: `{deck}`, `{n}` (deck number), `{artist}`, `{show}` (setlist), `{date}`, `{day}` (Sun), `{time}` (2015), `{seconds}` (201530). The time is when Record is pressed.

**Markers.** Press 1–7 to drop a marker at the playhead (Choreo, Audio, Video, Notes, Lighting, Pyro, Automation; M repeats the last type). Drag a marker to move it, click it to go there, right-click to rename or change its type. **Send / Export** sends them to a grandMA3 (a sequence with a cue per marker plus a timecode show that fires them from LTC) or onto a disguise track (notes, sections or CUE tags, placed through the track's TC tags), or exports a CSV or a grandMA3 plugin. Set the addresses in **Settings › Show control**. On the MA3, add an OSC line (Menu › In & Out › OSC) with this Mac as destination, Mode UDP, the port and prefix from Settings, and Enable Input, Receive and Receive Command on.

**OSC control.** Understudy listens for OSC on UDP 9000 (Settings › Show control): `/understudy/play`, `/pause`, `/toggle`, `/stop`, `/song/next`, `/song/prev`, `/song <n>`, `/marker` (last type), `/marker/<1–7 or type> ["label"]`, `/marker/next`, `/marker/prev`. Point a Stream Deck (through Companion's OSC module) or an MA3 macro (`SendOSC`) at it.

**Dante out.** To send the timeline onto a Dante network, install and start Audinate's Dante Virtual Soundcard (licensed per Mac) with 4 or more channels, then turn on **Settings › Dante out**. Song audio goes out on DVS channels 1–2 (left, right) and timecode on 3; subscribe receivers to them in Dante Controller. DVS chooses the network port itself; set **Network port** to the same one and Understudy warns if it loses its link. While DVS isn't running, song audio and LTC use the Timeline output settings.

**Recording from the timeline.** Set **Show code** to **Song timeline** (Settings › Timecode input, or tick **Show code for record** in the timeline window). In Stop and Record, show code then comes from the timeline instead of the LTC input. Press Record, then play the set: takes log against each song's own timecode with no cable. The song audio plays, and LTC out sends the same code to the decks' timecode inputs, disguise or another recorder. Play to code still chases the LTC input. For a quick test, **Record** under the timeline (⌥⌘R) does all of this in one step. If LTC out is off, it plays the songs' own timecode on the song-audio device's next channel (channel 3 when the music is on 1–2), with generated code between songs.

The footage comes from the selected take, so record a full run-through first.

## Running on a dedicated Mac

Understudy is meant to live on a Mac that stays at the rehearsal: a Mac mini on the show network is ideal. HyperDecks can't follow timecode in playback on their own, so a computer has to run it. In **Settings › Show machine**:

- **Keep this Mac awake** (on by default). The app also always opts out of App Nap, so its timing isn't throttled when the window is hidden or the display sleeps.
- **Start at login and relaunch if it quits unexpectedly** registers a launch agent bundled in the app. macOS may ask you to approve it under System Settings › General › Login Items. A normal Quit isn't relaunched. Only the copy the agent starts (at login) is watched: a copy opened by hand isn't, and Settings says which you're running. On a dedicated show Mac, let it start at login.
- **After a restart, go back to Record or Play** (off by default). When it happens, the header says so until you dismiss it. Decks that kept recording through the restart are left alone.

Only one copy runs at a time: a second launch hands over to the running one.

On the Mac itself: System Settings › Energy › *Start up automatically after a power failure*, automatic login, and Screen Sharing so you can watch and drive it from your laptop. Put it on a small UPS, and give LTC its own USB audio interface (the Mac mini's headphone jack is output only).

## Backing up takes

**Backup** copies the selected take off every connected deck into a folder on the Mac, by FTP, which HyperDecks serve on port 21 with no login. Choose a folder inside Dropbox and Dropbox syncs the files.

- Files land in `<folder>/<date>/<deck name>/<clip>`.
- Decks copy in parallel. A file already there at full size is skipped. An interrupted copy resumes.
- Backup is blocked while recording, and pressing **Record** cancels a backup in progress. Copying off a deck while it records isn't safe.
- Clips are found by name in the deck's media folders (slots, cache, USB), up to three levels deep.

## Signal flow

What to buy for three or four records at 2160p59.94 is in [docs/HARDWARE.md](docs/HARDWARE.md).

```
ME n ─SDI─▶ HyperDeck n SDI IN        HyperDeck n SDI OUT ─SDI─▶ disguise capture n
Show LTC ─DA─▶ Mac audio input  (+ HyperDeck TC IN, only needed for "record only while code runs")
House ref ─DA─▶ every HyperDeck REF IN  +  disguise capture cards
Mac ─Ethernet─▶ switch ─▶ HyperDecks (static IPs)
```

For the show itself, put a router or bypass in front of the disguise inputs so a deck fault can't take an IMAG feed.

The Mac's LTC input is now the single source of show code, so give it a clean, dedicated feed. A timecode box with jam-sync/freewheel in front of it is a cheap extra layer.

Lock the LTC generator to house ref, like the decks. If the two clocks drift apart, the map starts a new stretch whenever the difference passes about 1.5 frames, and the deck briefly re-parks there during playback.

## Deck setup (once per deck)

- Give each deck a static IP on the same network as the Mac.
- Feed house ref into **Ref In**.
- Format SSDs. All four decks should use the same codec and the same video format.
- Everything else is set by Understudy when you change mode: remote override, timecode input, record trigger, record prefix (deck name), preview/output, and timecode output = clip.

### Deck setup from the Mac

Each connected deck has **Setup**, a panel that reads the deck's own settings and keeps them current:

- **Media:** each slot's volume, status, recording time left and how full it is.
- **Recording:** codec, audio codec, record to cache, spill over to USB, time stamp in file names.
- **Input and reference:** video input, audio input, reference source, genlock input resync; default standard (read-only).
- **Managed by Understudy:** timecode input, drop-frame, timecode output, record trigger and file name prefix are shown but locked, because Understudy sets them on every mode change.
- **All decks** sets a value on every connected deck. A setting that differs between decks is flagged in amber; all decks should match.
- **Identify** flashes the deck's front-panel button.
- Changing codec or video input restarts the deck, so the panel asks first; Understudy reconnects on its own. Setup is locked while recording.

Recording resolution and frame rate always follow the deck's input, and playback output follows the clip: the HyperDeck protocol can't set either. Each deck column shows its **Input** (the format arriving, or **NO SIGNAL** in red).

### Confidence monitor

HyperDecks can't send pictures over the network, so for real pictures feed a **quad-split multiviewer** of the four deck outputs (e.g. Blackmagic MultiView 4, or a switcher/disguise multiview) into a **capture device the Mac sees as a camera**: a USB/UVC HDMI or SDI capture box, an ATEM Mini's webcam out, or a Web Presenter. Turn it on in **Settings › Confidence monitor**, pick the device, and say which quarter is which deck (or use *One deck* for a full-frame feed).

Each deck column then shows its picture, checked a few times a second at low resolution:

- **BLACK** (red): near black for 2 s (adjustable). A quick fade through black doesn't count; a dark stage with lights isn't black.
- **STILL** (amber): unchanged for 3 s (adjustable), shown only while the deck is playing, since a static shot during recording is normal.
- **NO FEED** (red): no frames from the capture device.

The checks ignore the edges and bottom of each quarter, where multiviewers draw borders, tallies and source labels. macOS asks once for camera access. The monitor shows what the multiviewer sees; feed it from the same SDI distribution as disguise for a good proxy of what disguise gets.

### HyperDeck Extreme 8K HDR

The Extreme uses the same Ethernet protocol as the Studio models, so Understudy controls it the same way. On each Extreme:

- **Ethernet protocol access: Enabled**, not *Enabled with security*. Understudy doesn't send a password; a secured deck shows a message saying so.
- **Video input: SDI.** 4xSDI mode records four separate channels into CH 1–4 folders, which Understudy doesn't support. Blackmagic documents 4xSDI playback as the channels playing one after another, not as four synced outputs, so one Extreme can't stand in for four decks.
- **Timecode input** is set by Understudy: Internal while recording continuously, External (the XLR LTC input) for *record only while show timecode runs*.
- **Changing the file format reboots the deck**; Understudy reconnects on its own.
- A deck at its client limit (other controllers, Companion, the Extreme's own web page) refuses another; Understudy says so and retries every 10 s.
- 8K (4320p), UHD/DCI 4K, HD and PsF formats are all recognised.

## App setup

1. Open **Settings** (`⌘,`) and pick the audio interface. Settings lists that device's input channels, by the device's own channel names, each with a live level meter. Click the one carrying LTC; it's marked **LTC** once code decodes. The show timecode rate is detected automatically (see below); you can fix it instead if you prefer. The main window's footer keeps a meter on the LTC channel.
2. Assign the decks. Pick the network to look on (**Network › On:**, e.g. the Ethernet adapter on the show network rather than Wi-Fi). Understudy looks for HyperDecks there: by Bonjour, and by asking every address on the Mac's subnets on port 9993, keeping only those that answer like a HyperDeck. They're listed under **Network**. Use **Assign** on a row, the **▾** next to a deck's address, or **Fill empty slots**. You can still type an address and press return. The first scan makes macOS ask for local network access; allow it, then **Find decks** again. Decks already connected are never probed, so a deck in use never gets a second client.
3. Check that each deck reads **Reference: LOCKED**.

## Operating

- **Record** (⌘2) before the run. Each recording deck reads **● REC**.
- **Stop** (⌘1) or **Play to code** (⌘3) after the run ends the take; leaving Record always asks first. Pressing the current mode again does nothing.
- **Play to code**: roll code (or let the show roll it), and each deck goes WAITING → CUEING → CHASING.
- **Deck health at a glance:** each column's bar and number are **green** when connected and **red** when a deck that was connected drops; **Media left** turns amber under 30 minutes and red under 10. The Decks header names lost decks and the lowest media.
- **Assign decks** (⇧⌘D) sets addresses and names and lists HyperDecks found on the network; changes apply only when you press Apply, and it's locked while recording. **Back up** (⌘B) and each deck's **Setup** (including play offset and Calibrate) are sheets, so the show screen stays calm.
- **Δ** shows the measured deck error in LTC frames. If a deck sits consistently early or late, press **Calibrate** to fold that error into its play offset.
- **TAKE** lets you pick an older run. Takes are matched across decks by position (latest, second latest, and so on). Each take says **SHOW CODE LOGGED**, **NO SHOW CODE LOGGED** (recorded with no LTC at all, so nothing to chase), or **CLIP TC** (no map; played from clip timecode).
- **NO MEDIA AT TC** means that code isn't in the selected take. The deck holds until code comes back into a recorded stretch.
- A deck that reconnects mid-REC carries on recording; one that wasn't recording is started.

## First hardware test — what to verify

This build is unit-tested on the timecode, LTC, protocol, take-map and chase logic. It has not yet been run against decks. On the bench, confirm the following:

1. **Internal timecode.** `configuration: timecode input: internal` and `configuration: timecode preference: dropframe|nondropframe` are accepted. If either isn't, the card shows the error. The deck's clock must count drop-frame exactly when show code does, or the map drifts by about 3.6 s an hour.
2. **Record timecode counts per recorded frame.** During REC, the deck's display timecode should advance one frame per recorded frame. In PLAY TC, a frame's clip timecode should match what was displayed when it was recorded. This is what the map relies on.
3. **Combined goto.** `goto: clip id: N clip: F` is accepted by your firmware. If it isn't, the app falls back to two separate commands, and the card will show the error once.
4. **Deck timecode base.** At 2160p59.94, check whether the deck reports display timecode frames 0–59 or 0–29. The default assumes 0–59. If your deck reports 0–29, turn off *Deck timecode counts at video rate* in Settings.
5. **Dropout drill.** Pull the LTC cable mid-REC for 10 s, plug it back, STOP, then PLAY TC through that section. Then try a timecode jump mid-take.
6. **Play latency.** Check Δ after a few rolls and calibrate.
7. **Pass-through.** In STOP / REC, confirm the deck's SDI out passes the live input to disguise.
8. **Local network permission (macOS 15+).** On first launch, allow Understudy when macOS asks.
9. **HyperDeck Extreme 8K.** Repeat 1–4 on an Extreme at 4320p and 2160p, and confirm `clips get: version: 2` lists clips recorded to its cache or USB-C drive.
10. **FTP backup.** Back up a take from each deck model you use, and confirm the files open. Check the folder layout the deck's FTP shows.
11. **Show machine.** Turn on *Start at login*, approve it, force-quit Understudy (⌥⌘⎋), and confirm it relaunches.
12. **Confidence monitor.** With the capture device and multiviewer you'll use, check the quadrant mapping, that a black source reads BLACK despite the multiviewer's labels, and CPU use on the Mac mini.

## Build

Runs on macOS 13+. Building needs Swift 6 (Xcode 16 or its Command Line Tools).

```sh
./scripts/test.sh          # core logic tests (Swift Testing; works without Xcode)
swift run Understudy         # run unbundled while developing
./scripts/build-app.sh     # dist/Understudy.app + zip (ad-hoc signed)
```

`build-app.sh` makes a universal (Apple silicon + Intel) app when full Xcode is installed, and an app for this Mac's chip otherwise.

Pushing a tag like `v0.2.0` runs CI and attaches the zipped universal app to a GitHub release.

The first launch of an ad-hoc signed build needs right-click → **Open**.

The app icon is drawn by `swift scripts/make-icon.swift`, which writes `Resources/AppIcon.icns`. It needs Neue Haas Grotesk Display installed, so the `.icns` is committed and CI doesn't redraw it.

## Layout

```
Sources/UnderstudyCore   timecode math, LTC decoder/encoder, HyperDeck protocol, take maps, chase engine, settings (pure, tested)
Sources/Understudy       SwiftUI app, Core Audio LTC input, Network.framework deck client, take map storage
Tests/                 Swift Testing suites for the core
scripts/               test.sh, build-app.sh
```
