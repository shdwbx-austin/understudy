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

1. It looks the incoming code up in the take's map and parks the deck slightly ahead (pre-roll).
2. It fires `play` when code reaches that point, early by the deck's start latency.
3. It watches the deck's timecode ten times a second.
4. It re-parks the deck if the deck drifts out of tolerance, or if code moves into a different recorded stretch.

## Running on a dedicated Mac

Understudy is meant to live on a Mac that stays at the rehearsal: a Mac mini on the show network is ideal. HyperDecks can't follow timecode in playback on their own, so a computer has to run it. In **Settings › Show machine**:

- **Keep this Mac awake** (on by default). The app also always opts out of App Nap, so its timing isn't throttled when the window is hidden or the display sleeps.
- **Start at login and relaunch if it quits unexpectedly** registers a launch agent bundled in the app. macOS may ask you to approve it under System Settings › General › Login Items. A normal Quit isn't relaunched.
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

## Layout

```
Sources/UnderstudyCore   timecode math, LTC decoder/encoder, HyperDeck protocol, take maps, chase engine, settings (pure, tested)
Sources/Understudy       SwiftUI app, Core Audio LTC input, Network.framework deck client, take map storage
Tests/                 Swift Testing suites for the core
scripts/               test.sh, build-app.sh
```
