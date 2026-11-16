# Changelog

## 0.7.1 — 2026-11-16

- **Fixed: the beat grid didn't appear after setting a tempo** (and GRID kept asking for one). The tempo was saved, but the timeline drew from a copy of the song that only refreshed when the set changed. Tempo and downbeat changes now show at once, without interrupting playback.
- **The grid shows without zooming**: every bar, or every 2nd, 4th or 8th bar when they'd be too close; beats appear as you zoom in.
- **The marker list follows the playhead**: the marker just passed gets a red bar (like the playhead) and the list scrolls to keep it in view while playing or scrubbing; it stays put while you're typing a label.
- **Arraying is clearer**: the tempo box takes “120”, “120 bpm” or “92,5”, and an empty or unreadable tempo, or no room for hits, now says so instead of doing nothing. New hits are selected (so they stand out and can be dragged together) and the grid turns on.

## 0.7.0 — 2026-11-16

- **A clearer loop.** Outside the loop is dimmed, with solid edges, a bar along the top and a label with its times and length. Clear it with the label's ×, the × by LOOP, Clear Loop in its menu, or ⇧L.
- **Drag along the ruler to draw a loop** above the current song (the song itself still scrubs).
- **Beat grid.** Each song can have a tempo and beats per bar (right-click › Tempo…, or GRID by the ruler; a BPM in the audio file's name is offered) and a downbeat (Set Downbeat at Playhead). Bar and beat lines with bar numbers appear as you zoom in.
- **Array markers on the grid.** Right-click a marker › Array From Here…: hits of its type every bar, 1/2, 1/4, 1/8, 1/16 or 1/8 triplet, until the next marker, the song's end, the loop's end, or a count. Each hit is placed from the first marker's exact time, so there's no drift. An array is one row in the list and small ticks on the track, and clears in one go (its ×, Clear This Array, or Clear arrays above the list); hand-placed markers stay.
- **Move a selection on the timeline:** select markers in the list, then drag any one of them left or right on the track; they all move.

## 0.6.0 — 2026-11-16

- **Loop a song or a section.** LOOP under the timeline loops the song under the playhead (from its lead-in) or a section: I and O at the playhead, or two selected markers › Loop Between Them. L turns it on and off. Sections are held on show code, so they follow their song when the set is reordered. Shown as a bar on the set and a band on the current song.
- **Stop after song.** The timeline can stop at the end of each song, parked on the next song's lead-in, instead of rolling on.
- **Downtime between songs.** Time before each lead-in with no code, audio or LTC out, like a show's changeovers; the decks wait on the next song's first frame and the bar counts down. Lead-in and downtime share one control under the timeline.
- **Edit several markers at once.** ⌘-click or ⇧-click markers on the track or in the list (or Select all), then change their type, label, move them by frames or seconds, loop between them, or delete them together. Dragging one of a selection moves them all.
- **Zoom into the current song** (pinch, ⌘= / ⌘−, + / − by the ruler, ⌘0 for the whole song). The view follows the playhead and the ruler goes down to frames.
- Loop, stop-after-song and downtime are saved with the project.

## 0.5.0 — 2026-11-16

- **Program · View · Decks.** The main window is now three screens, built around the timeline for lighting and screens programmers and producers:
  - **Program** (⌘1) is the timeline workspace: playlist, set, current song, markers, transport. The decks follow it.
  - **View** (⌘2) shows the take's pictures, locked to the timeline: ME 1 large with the other decks beside it (click to swap) or side by side, the set and transport underneath, NDI out at the bottom.
  - **Decks** (⌘3) holds everything about the recorders: Control (show code, Stop · Record · Play to code · Follow Program, the take, each deck, Assign and Setup) and the decks' settings, moved out of Settings: Timecode in, Recording, Playback, Backup.
  - A strip on every screen says what the decks are doing (Recording, Playing to code, Following Program, Stopped); click it for Decks. Program and View take the decks (leaving Record asks first); anything that stops them following the timeline brings Decks up.
  - Keys: ⌘1–3 are the screens. The deck modes moved to the Decks menu: Stop ⇧⌘., Record ⇧⌘R, Play to code ⇧⌘P, Follow Program ⇧⌘F. The video window is View › Video in a Window (⌥⌘V).
  - Settings keeps this Mac's things: General, Audio out, Show control.
- **Understudy is a sidecar for programming workflows**: the start window, show header, installer and README now say so, in place of "stands in for the cameras between run-throughs".
- **Markers in Understudy's own style**: square tags with the type's key number, a hairline down the track and labels in small mono capitals beside the tag; type chips are swatches (colour bar, key, name). New default palette: coral, teal, violet, stone, sodium yellow, hot pink and sky, kept clear of the status colours. Crowded labels drop to lanes below instead of covering the next tag. Existing projects keep their colours.
- **Marker types are easy to find**: **Edit types…** beside the chips, Markers › Edit Marker Types… (⌥⌘M) in the menu bar, and on every chip's right-click menu.
- **[ and ] always work**: next/previous marker, the number keys and M are read straight from the timeline window's keys. Before, [ and ] lived in the Send / Export pull-down and only sometimes registered. Typing in a text field is left alone, and ] now steps past a marker it just landed on even while playing.
- **More room for the timeline**: a narrower playlist, a taller current-song track, and one-line deck chips in the Timeline view.

## 0.4.0 — 2026-11-16

- **Video viewer** (⌥⌘V, or Video in the Timeline bar): the selected take's recordings for up to three decks, played in Understudy and locked to the timeline's timecode exactly as the decks chase it (take maps included): playing from the right frame, parked on the playhead's frame when paused, re-locked if it drifts. Show one deck (ME 1…) or all side by side. Files come from the backup folder and are pulled into the project (`objects/VideoFile/<deck>/`), playing straight away while they copy. Timeline mode only.
- **NDI out**: each video as its own NDI stream ("Understudy ME 1", "Understudy ME 2", "Understudy AUX 1"), at 1080p or the files' own size. Needs libndi from the NDI SDK, bundled in the app at build time (see README). Tested on a real 4K ProRes take: lock within 0.06 frames, three streams discovered and received at the file's rate.

## 0.3.1 — 2026-11-16

- **Switching to Timeline parks the decks at once** on the playhead's frame, ready to roll on Play. Before, a deck whose takes hadn't arrived yet was skipped until the playhead moved.
- **Softer Timeline top bar**: the modes are light Haas words with a fine underline for the current one (no outlined mono tabs), the clock's state and Open in window are in light type, Send / Export matches, and marker chips use gentler tints.

## 0.3.0 — 2026-11-16

- **Timeline mode (⌘4) and a song timeline (⌘T).** In Timeline mode the main window becomes a workspace: the playlist (set and library) down the left, and on the right the whole set to scrub, the current song up close with a seconds ruler, the transport, the take and a status chip per deck. Two-finger swipes, a mouse's side wheel or Shift + wheel scrub across the set, and step frame by frame over the current song.
  - **Songs:** import a song list (CSV: name, start timecode, optional end or Duration), then drop an audio file on each song. Headers like "LTC Start Point" are recognised, ruled lines are ignored, and songs with no start (blank or n/a) are skipped and listed. An alphabetical list is laid out in timecode order.
  - **Clock:** the timeline is the master. It plays the song audio, drives the decks through the chase engine, and can output LTC that follows it (Settings › Timeline output).
  - **Set list:** imported songs form a library; tonight's set is the songs you add (+), in your order. Only the set plays. An alphabetical sheet lands in the library; a running-order list becomes the set. Re-importing keeps the set, its order and attached audio.
  - **Find audio…:** pick a folder and audio files (in it and its subfolders) are matched to songs by name, extras like track numbers, BPM and "SMPTE 03" ignored. The most specific song wins ("Matchbox (no intro)" over "Matchbox"), and acoustic, instrumental, click and stem files only go to songs that say so. Songs that already have audio keep it.
  - **Waveforms:** each song's audio is drawn on the set and, large, on the current song, read in the background and cached so they're instant next time.
  - **Timecode in the audio:** each song's file is scanned for LTC on any channel. That channel is muted on the music output and left out of the waveform, the audio is lined up by its own code, and LTC out plays the track's timecode instead of the generator (the generator fills the gaps). Both can be overridden: right-click a song › Play Timecode Channel, and Settings › Timeline output › Use the track's own timecode. Songs with timecode show TC in the playlist.
  - **Setlists:** save the set under a name, keep several (Setlist menu: New, Save As, Rename, Delete) and switch between them. The current setlist follows your edits.
  - **Order by take:** after each take, the set can reorder itself into the order the songs were actually played, read from where each song's code landed in the take (Setlist › Order Set by Latest Take, or turn on Auto-Order After Each Take). A song counts once at least 10 s of it (or half, for short songs) was played.
  - **Readable playlist:** the playlist widens to fit the longest song name, and song names on the set wrap and shrink instead of being cut off.
  - **Record decks (dev):** a Record button under the timeline (and Record from Timeline, ⌥⌘R) sets show code to the timeline, starts the decks recording and plays the set, for testing a run without an LTC source. With LTC out off, the songs' own timecode plays out on the song-audio device's next channel (3 when music is on 1–2), with generated code between songs; LTC out, when set, takes priority. Changing outputs while the timeline plays no longer stops the song audio.
  - **Reorder:** drag songs in the set to rehearse them in any order. Each song gets a lead-in so the decks are parked and rolling on its first frame.
  - **Timecode source for recording:** Settings › Timecode input › Show code: Song timeline (or the SHOW CODE FOR RECORD box in the timeline window). Stop and Record then take show code from the timeline, so takes log against it with no cable, while LTC out sends the same code to the decks' timecode inputs, disguise or another recorder.
  - **Scrub and step:** drag the playhead, or use frame steps (← →), one-second steps (⇧← →) and song jumps (⌥← →). While paused, the decks seek to the exact frame.

- **Settings in tabs**: General (show machine, backup, projects folder) · Timecode (show code, LTC inputs, rate, dropout coasting) · Recording (mode, file names) · Playback (fast pickup; chase tuning and the confidence monitor folded under Advanced) · Audio out (song audio and LTC out first, then Dante and AES67) · Show control (OSC, grandMA3, disguise). The show-critical setting leads each tab, and Settings reopens on the last tab used. The dev Record button left the timeline (Mode › Record from Timeline, ⌥⌘R, stays).

- **Calmer Timeline view.** In Timeline mode the big clock and the Mode row become one bar: name and project, the modes as compact tabs (⌘1–4 as before), Window ⌘T, and the show timecode with its state. The playlist **collapses** (sidebar button or ⌃⌘S, remembered) to give the timeline the full width, its Find audio / Import CSV / order / clear actions moved into one ··· menu, and the instruction caption over the set became a tooltip. The current song's track takes the room this frees.

- **AES67 out (test)** (Settings › AES67 out): the timeline's left, right and timecode as one 3-channel L24/48 kHz AES67 stream (1 ms packets) to a multicast group (239.69.x.y from this Mac's address by default) out of the network port you choose, announced by SAP so Dante Controller lists it on a device in AES67 mode. It locks to the network's PTPv2 master (a Dante device in AES67 mode provides one) and re-announces when the master changes; with no master it free-runs, which Dante won't play. Channel 3 carries the same timecode as LTC out (the song's own, or generated). Tested on this Mac over loopback against a simulated PTP master: 1000 packets/s with no gaps, both music channels and continuous timecode decoded from the stream; the clock steps once when it first locks. Not yet tried with Dante hardware. (This Mac's network MIDI service holds UDP 5004, so the stream can't be monitored on the sending Mac at the default port.)

- **Custom marker types**, saved with the project: Send / Export › Edit Marker Types… adds, renames, recolours (colour picker), reorders (drag; the first nine are keys 1–9 and OSC `/marker/1`–`9`) and removes types. Removing a type in use moves its markers to another type or deletes them; Reset to defaults brings back the seven. OSC `/marker/<name>` and `/marker "<name>"` take your own names, and grandMA3, disguise and CSV exports use them. Projects and markers made before keep their types.

- **Updates itself** from GitHub Releases (Sparkle): checks once a day and from Understudy › Check for Updates…, downloads in the background and installs on relaunch. The start window shows the version and whether you're up to date. Needs the release signing setup in docs/RELEASING.md; builds without an update key have updating switched off.
- **Installer**: `Understudy-<version>.pkg` installs to /Applications and hands the app to the person who installed it, so updates never ask for an admin password. CI signs it and the app with the Developer ID, notarizes both and publishes the update feed (appcast.xml) with each tagged release, once the secrets in docs/RELEASING.md are added.

- **Projects**, laid out like disguise projects: `<Name>/<Name>.understudy` (the show: songs, set, setlists, markers, decks, recording names, grandMA3/disguise targets), `history/` (a snapshot at most every 5 minutes, last 50 kept), `objects/AudioFile`, `objects/SongList`, `objects/Export` (files copied in) and `internal/analysis` (waveform and timecode caches). Audio you attach or find is copied into the project in the background while the song already plays from the original, then switched over; imported song lists are copied too. File › Copy All Audio Into Project collects the rest. Paths inside the project are stored relative, so the folder can move to another drive or Mac.
  - **Start window** (after CuePoints): recent projects, Open…, New Project, and the projects folder (Change…; `~/Documents/Understudy Projects` by default). The show you had before projects is offered as your first project. **Open the last project at launch** skips it on a show machine (and a crash relaunch or resumed Record/Play always reopens the last project).
  - File menu: New Project… (⌘N, optionally starting from the open show), Open Project… (⌘O), Open Recent, Show Project in Finder, Close Project (⇧⌘W), Start Window. Projects can't be switched while recording.
- **Up to 16 decks**, saved with the project: Assign decks has **+ Add deck** and a × per deck (the ones after it move up, and their take maps go with them). Deck chips in Timeline mode wrap four to a row; decks past the first four can be left off the confidence multiviewer.

- **Recording names** (Settings › Recording): decks now record as `deckname_artist_date_time`, e.g. `ME_1_RKS_2026-11-15_2015_0001.mov` (the deck adds the take number). Set the artist there, or write your own template from `{deck}`, `{n}`, `{artist}`, `{show}`, `{date}`, `{day}`, `{time}`, `{seconds}`; a preview shows each deck's next file name. The time is when Record is pressed, shared by every deck in the take. Spaces and symbols become `_`, and an empty token drops out with its separator (so a stray space no longer gives names like `_ME_1`).

- **Markers**, after CuePoints: seven types (Choreo, Audio, Video, Notes, Lighting, Pyro, Automation), each with its colour and key. Press 1–7 (or click a type) to drop one at the playhead, M for the last type again; drag a marker's handle to move it (frame by frame), click to go there, right-click to rename, retype or delete. Markers sit on show timecode, so they stay with their song in any running order. They show on the current song (labels stacked so they don't collide), as ticks across the whole set, and in a list beside the song (this song or the whole set; double-click a label to edit). [ and ] jump between markers. Right-click a type to hide it.
- **OSC control** (Settings › Show control): play, pause, toggle, songs and markers from a Stream Deck (Companion), a grandMA3 or anything that sends OSC, on UDP 9000 by default. `/understudy/play`, `/pause`, `/toggle`, `/song/next`, `/song <n>`, `/marker`, `/marker/<type> "label"`, `/marker/next`… Buttons that send 1 then 0 act on press only. Settings shows the last message received, to check a controller is reaching Understudy.
- **Send markers to grandMA3** over OSC: Understudy builds a sequence with one named cue per marker and a timecode show whose events Goto those cues at the marker times, so MA3 fires them from LTC with nothing to import. Sequence and timecode show numbers are set in Settings (1001 and 101 by default) and the send asks before replacing them. **Export grandMA3 Plugin…** writes the same build as a plugin for a console that isn't on the network.
- **Send markers to disguise** (r27+): writes them onto a track as notes, notes + sections, or CUE tags + notes, through Designer's session API. Each marker is placed through the track's TC tags, so a song's markers land on that song; tracks without TC tags use a start timecode from Settings.
- **Export CSV…**: timecode, type, label, song and seconds for every marker.

- **Seek while playing.** Click anywhere on the set or the current song, drag the playhead, or swipe/side-scroll, and the timeline keeps playing from the new spot instead of stopping. The decks follow (parked under the playhead while you move, then picked up at once), and song audio and LTC out stay silent while you're seeking and start again in place when you stop. Paused, side-scrolling over the song still steps frame by frame.
- **Faster timeline.** The playhead, show clock and meters now redraw on their own, so the playlist, waveforms and deck rows aren't redrawn every frame: about 3× less main-thread work per frame with a 20-song set (2.8 ms, was 7–8.5 ms).

- **Decks pick up at once.** When code starts or jumps, each deck now gets goto and play together, aimed just far enough ahead to cover its goto and start delay, instead of being parked a pre-roll ahead and given half a second to settle. Measured on a HyperDeck Studio 4K Pro: in sync 50–85 ms after code starts or jumps (was 820 ms), and with the timeline on Play in Timeline mode. Settings › Chase › Fast pickup (on by default); the old park-ahead behaviour is still there with it off.
  - A deck that stops by itself while chasing is started again within a frame, not after drift checks (about 0.7 s).
  - A deck holding steadily half a frame or more off has its play offset trimmed, without a re-park, so the next start lands closer.
- Fixed: cues landed one frame early. The deck numbers a clip's frames from 1, so a cue to the clip's first frame was rejected and every other cue parked a frame short. Play offsets learned before this may now be up to a frame high; the trim corrects them, or press Calibrate.
- Fixed: in Timeline mode, drift checks compared the decks against the LTC input instead of the timeline.

- **Dante out** (Settings › Dante out): sends the timeline to a Dante network through Dante Virtual Soundcard: song audio left and right on DVS channels 1–2 and timecode on 3, all on one device so they stay sample-locked. DVS is found by its driver, followed when it starts, stops or restarts, and checked for at least 3 channels. Pick the network port Dante is on and Understudy warns when it loses its link. Until DVS is running, audio uses the normal timeline outputs.

- **Learns each deck's start delay.** A HyperDeck starts a few frames late after Play, so with a 0 play offset it sat steadily behind code and was re-parked every few seconds: a visible stutter. When a deck holds a steady, consistent offset, Understudy now adds it to that deck's play offset (the value Calibrate sets) and re-parks once. A deck far off code (about 9 frames or more) is re-parked after two readings instead of waiting out the back-off.
- Fixed: with a short pre-roll (0.5 s) and the default 0.5 s cue settle, Play to code never armed the deck. It re-parked the deck about once a second instead, so the picture stepped forward a second at a time. Pre-roll is now always at least the settle time plus the deck's start offset and a margin, and Settings no longer offers less than 1 s.
- Fixed: Find decks could list this Mac's own network addresses as HyperDecks when something on the Mac answered on port 9993. Discovery now skips every address that belongs to this Mac.
- **App icon** for the Dock and Finder: a lowercase u in Neue Haas Grotesk with the green the clock turns on lock, drawn by `scripts/make-icon.swift`.

## 0.2.0 — 2026-11-14

- **Finds HyperDecks on the network**, by Bonjour and by a scan of the local subnets on port 9993 that keeps only hosts greeting like a HyperDeck. Found decks can be assigned to a slot or used to fill empty slots.
- **Timecode hardening** (from an independent bug sweep, failure cases reproduced in tests): rate detection times frame intervals and skips missed frames (a lossy 30 fps signal no longer locks as 29.97) and confirms even the first lock; a single corrupt LTC frame no longer counts as a jump (a jump needs a second agreeing frame); deck timecode is read the way the deck says it counts (its timecode preference) and stored with each take map; a deck reset mid-chase is stopped rather than left playing; repeated drift re-locks back off; a fixed rate contradicted by incoming code pauses chase and logging; audio interfaces are followed when unplugged/replugged and a dead input is retried; false-start takes no longer swap maps with the real run; STILL ignores small movement in a static shot.
- **Networking hardening** (from an independent bug sweep): a dead link (pulled cable) is detected within ~6 s by a reply watchdog with idle pings; a deck that was offline when Stop was pressed is stopped when it reconnects; replies from a replaced connection can't update the wrong deck; dropped links no longer read as "too many clients"; a hung deck whose network stack still accepts connections no longer flips back to green on reconnect (a deck counts as connected only once it greets); cancelling a backup can no longer crash the app, and stalled FTP copies time out; Bonjour only browses while Assign decks is open and Fill skips busy decks; a normal Quit doesn't resume Record next launch.
- **Show-critical polish**: green/red deck connection state (red only for a deck that was connected and dropped), recording time left per deck with warnings, one large status word per deck, timecode NO LTC in red during Record/Play, equal deck columns, a fixed layout that doesn't jump between modes.
- **Safer controls**: re-pressing the current mode does nothing (it used to split takes / re-cue decks); leaving Record asks first; deck assignment is a draft applied with Apply and locked while recording; a deck leaving its slot mid-take is told to stop; backup has its own take choice; picking an older take turns off Follow latest; single main window.
- **Calmer show screen**: Assign decks and Backup moved to sheets; play offset and Calibrate moved to each deck's Setup; LTC meter no longer shows normal levels in amber.
- **Confidence monitor**: deck pictures from a capture device (quad multiviewer or one deck), with BLACK / STILL / NO FEED checks that ignore multiviewer borders and labels. Off by default.
- **Deck setup from the Mac**: a per-deck panel for codec, audio, cache/USB spill, video input, reference and genlock, with media status, Identify, All decks and mismatch flags. Settings Understudy manages are shown locked; restart-causing changes ask first; locked while recording.
- **Input signal per deck**: each column shows the arriving format or NO SIGNAL. Fixed: a lost input kept showing its last format.
- **Separate playback timecode input** (optional): Stop and Record read show timecode, Play to code reads a local review source, with no repatching. Same interface or two.
- **Show machine mode** for a dedicated Mac: keep the Mac awake (and never App Nap), start at login and relaunch after a crash (bundled launch agent), optionally resume Record or Play after a restart with a banner, and one copy at a time.
- **Pick the network interface** discovery looks on (listed by macOS port name and subnet).
- **Back up takes** off the decks by FTP into dated per-deck folders, e.g. in Dropbox: parallel per deck, skips files already there, resumes interrupted copies, blocked while recording.
- **HyperDeck Extreme 8K HDR checked against Blackmagic's protocol document.** PsF formats (e.g. 1080PsF2398) are now recognised, alongside 8K, DCI and dotted names. A deck at its client limit (`120 connection failed`) gets a clear message and a 10 s back-off instead of a 2 s retry loop. Decks with protocol security on (`122`), remote disabled (`111`) or rebooting (`213`) say what to do.
- **Steady clock that shows lock.** Timecode is set in fixed-width cells, because Neue Haas Grotesk's figures are proportional, so digits no longer shift as they change. The show clock is grey when stopped, off-white while acquiring, green when locked, and amber when freewheeling.
- **Redesigned in the Shdwbx house style**: Swiss grid (label column + four columns), numbered sections, hairline rules, Neue Haas Grotesk and Space Mono, black / off-white / signal green, amber and red. Show timecode is four labelled blocks (hours, minutes, seconds, frames) sized to the window; decks are full-width rows with a large slot number, deck timecode and a small table of input, reference and media left. A lost deck's row turns solid red. All four decks fit on a 1440×900 laptop screen without scrolling.
- **Renamed from cam4prog to Understudy.** The bundle ID is unchanged, so saved settings and macOS permissions carry over. Saved take maps move to the new folder on first launch.
- **Recording no longer depends on show timecode.** In the new default mode, decks record from REC until STOP, stamped with their own clock. Understudy logs show LTC against each take as a timecode map, so dropouts and jumps no longer stop or break a recording.
- Playback looks show code up in the take's map: it holds at gaps, re-parks at jumps, and plays the latest pass of re-rolled code. Takes without a map play from clip timecode, as before.
- **Show timecode rate is detected automatically** from incoming LTC (23.976, 24, 25, 29.97 DF/NDF, 30), and playback follows it. A fixed rate is still available.
- LTC frames now reach the app strictly in order.
- Fixed: changing the LTC channel could leave the whole input silent or crash. Changing channel no longer restarts audio at all, a device change reuses one audio engine, and a watchdog reopens the input if it ever stops delivering audio.
- Fixed: picking an audio device other than the system default only showed one channel, and read the input at the default device's sample rate.
- **Live input meters.** Settings lists only the selected device's channels, by name, each with a level meter; click one to use it for LTC. The main window shows the LTC channel's level.
- The show clock freewheels through LTC dropouts (2 s by default, adjustable). The header shows FREEWHEEL while it does.
- A deck that reconnects mid-REC keeps recording; one that wasn't recording is started.
- Settings saved by older versions keep loading (deck IPs and names are kept) when new settings are added.
- The previous behaviour stays available as *Record only while show timecode runs*.
- `build-app.sh` builds for the current Mac's chip when full Xcode isn't installed.
- Deck replies now reach the app in the order the deck sent them. Before, state changes, notifications and command replies could swap order.
- Changing a deck's IP no longer lets the old connection's late "disconnected" mark the new connection as down.
- Saved settings with a missing or extra deck no longer crash the app on launch.
- Tests moved to Swift Testing, so `./scripts/test.sh` runs on a Mac with only the Command Line Tools. CI runs on macOS 15.

## 0.1.0 — first build

- Three modes: **STOP**, **REC ARM** (decks record on timecode run), **PLAY TC** (decks chase show LTC).
- LTC decoder reading any Core Audio input/channel, 23.976–30 fps, drop and non-drop.
- Up to four HyperDecks over the Ethernet protocol (TCP 9993), auto-reconnect.
- Chase: pre-roll cue, early play fire with per-deck offset, drift monitoring and automatic re-lock.
- Take picker matched by position across decks, follow-latest option.
- Calibrate button folds measured drift into each deck's play offset.
