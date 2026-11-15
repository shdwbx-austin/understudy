# Changelog

## Unreleased

- **Timeline mode (⌘4) and a song timeline (⌘T).**
  - **Songs:** import a song list (CSV: name, start timecode, optional end or Duration), then drop an audio file on each song. Headers like "LTC Start Point" are recognised, ruled lines are ignored, and songs with no start (blank or n/a) are skipped and listed. An alphabetical list is laid out in timecode order.
  - **Clock:** the timeline is the master. It plays the song audio, drives the decks through the chase engine, and can output LTC that follows it (Settings › Timeline output).
  - **Reorder:** drag songs in the list to rehearse them in any order. Each song gets a lead-in so the decks are parked and rolling on its first frame.
  - **Scrub and step:** drag the playhead, or use frame steps (← →), one-second steps (⇧← →) and song jumps (⌥← →). While paused, the decks seek to the exact frame.

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
