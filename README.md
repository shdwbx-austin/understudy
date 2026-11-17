# understudy

**A sidecar for programming workflows.**

Understudy sits beside the lighting console and media servers while a show is programmed:

- **Record and play back the cameras.** Record up to 16 broadcast MEs on HyperDecks, then play them into the disguise capture inputs locked to show timecode, so you can program against real SDI between run-throughs with no files to copy and no transcoding.
- **Run the show without the band.** A song timeline with each track's own timecode, setlists, timecode out and a video viewer with NDI feeds, for rehearsing songs in any order.
- **Mark it up and hand it on.** Markers with your own types, sent to grandMA3 (sequence and timecode show) and disguise (track notes, sections and tags), or exported as CSV.
- **Drive it from the desk.** OSC from a Stream Deck, grandMA3 or anything else: transport, modes, songs and markers.

Shdwbx · Design and Creative Support

---

## What it does

The main window has three screens. A strip at the top of every screen says what the decks are doing; click it to go to Record.

| Screen | What it's for | The decks |
| --- | --- | --- |
| **Program** `⌘1` | The timeline: playlist and setlists, the set, the current song, markers, transport, and every deck's status in one row (they shrink to numbered squares in the status colour when there are many; hover for details) | Follow the timeline: parked on the playhead, rolling with it |
| **View** `⌘2` | The take's pictures, locked to the timeline: ME 1 large (or side by side), NDI out | Follow the timeline |
| **Record** `⌘3` | Record, play to code, the take, every deck's health, and the decks' settings: timecode in, recording, playback, backup | Whatever you set here |

Program and View take the decks: going to either puts them into Follow Program, and if they're recording it asks first. On Record they do what you tell them (Record menu):

| Decks do | Key | disguise sees |
| --- | --- | --- |
| **Stop** | `⇧⌘.` | Live ME (passes through the deck) |
| **Record** | `⇧⌘R` | Live ME |
| **Play to code** | `⇧⌘P` | Recorded ME, chasing show LTC from the selected take |
| **Follow Program** | `⇧⌘F` | Recorded ME, following the timeline |

After a run-through, hit **Play to code** (or go back to Program). The latest take is selected, and the decks follow code every time you roll it.

### Recording survives timecode failures

By default the decks record continuously from **REC** until **STOP**, stamped with their own clock. Show LTC doesn't start or stop anything. While they record, Understudy reads each deck's timecode ten times a second, pairs it with show LTC at that instant, and saves a timecode map for the take.

- **LTC drops out:** the decks keep recording. Code that never arrived just isn't in the map. If code comes back where it should be, the map carries straight across the gap.
- **LTC jumps** (per-song code, a re-roll): the map starts a new stretch. If the same code is rolled twice in one take, playback uses the later pass.
- **Short dropouts:** the show clock coasts (freewheels) for 2 s by default, so a glitch doesn't stop playback or re-park the decks. The header shows **FREEWHEEL · NO LTC** while it coasts.

Maps live in `~/Library/Application Support/Understudy/takemaps/`. The map in progress is saved every 5 s, so a crash mid-take loses only a few seconds of it.

If you'd rather have the decks record only while code runs and stamp clips with show code (v0.1.0 behaviour), choose **Record › Recording › Only while show timecode runs**. A dropout then stops the recording. Takes without a map are played back from their clip timecode, so recordings made that way, or with 0.1.0, still work.

### Separate show and playback timecode inputs

To review against a local timecode source without repatching, turn on **Record › Timecode in › Use a separate input for Play to code** and pick its device and channel. Stop and Record read **Show timecode**; Play to code reads **Playback timecode**. The header and footer say which is in use.

- Both inputs can be channels on one interface (the switch is instant) or on two interfaces (the input reopens).
- The playback source must carry the **same timecode values** as the show (e.g. a local playback of the show's timecode track), because takes are mapped against show code.
- Each input's rate is measured afresh when it's switched in, so chasing starts about 2 seconds after entering Play.

### Timecode rate is detected automatically

Understudy works out the show timecode rate from the incoming LTC and follows it, including drop-frame. It can tell 23.976 from 24 and 29.97 from 30, timing frames on the audio sample clock, within about 2 seconds of code. The header shows **AUTO 29.97 DF** (or whatever it found) and the measured rate.

- **Before the rate is known**, recording logs and playback wait. That's only the first couple of seconds of code after launch or after changing the audio input. Decks still record.
- **If the show switches to a different rate**, the new rate must hold for 2 seconds before Understudy follows it.
- **Takes stay valid across rates**, because take maps are stored in seconds.
- **A fixed rate** can be set under **Record › Timecode in › Show timecode rate**. The header then warns if incoming code doesn't match it.

### Playback

HyperDecks can't chase LTC natively. Understudy reads the show LTC itself and handles each deck in four steps:

1. When code starts or jumps, it looks the code up in the take's map and sends the deck to the matching frame and plays it in one go, aimed a few frames ahead to cover the deck's goto (about 20 ms) and start delay (its play offset). On a HyperDeck Studio 4K Pro the deck is in sync about 85 ms later; in Program, where the decks are already parked on the playhead, it rolls with the timeline.
2. It watches the deck's timecode ten times a second.
3. It re-parks the deck if it drifts out of tolerance, if code moves into a different recorded stretch, or if the deck stops by itself.
4. If the deck holds steadily half a frame or more off, it trims the deck's play offset so the next start lands closer.

**Fast pickup** is on by default (Record › Playback). Turn it off to park decks pre-roll ahead and fire `play` once they've settled: slower to pick up, for decks that locate slowly.

## Installing and updates

Install with `Understudy-<version>.pkg` from the [latest release](https://github.com/shdwbx-austin/understudy/releases/latest). After that Understudy updates itself: it checks GitHub once a day (or Understudy › Check for Updates…) and installs new versions on relaunch. Releasing is in [docs/RELEASING.md](docs/RELEASING.md); how the UI is designed and built is in [docs/UI-GUIDE.md](docs/UI-GUIDE.md).

## Projects

Each show is a project folder, laid out like a disguise project:

```
<Projects folder>/<Name>/
  <Name>.understudy     songs, set, setlists, markers, decks, recording names, MA3/disguise targets, playback LUTs
  history/              snapshots, at most one every 5 minutes (last 50 kept)
  objects/AudioFile/    song audio, copied in
  objects/SongList/     imported song lists
  objects/Export/       marker exports
  objects/LUT/          .cube Playback LUTs (viewer and NDI out only)
  internal/analysis/    waveform and timecode caches
```

Understudy opens on a start window with recent projects, **Open…** and **New Project**, and the projects folder (**Change…**). Audio and song lists you bring in are copied into the project; File › **Copy All Audio Into Project** collects anything still outside it. On a show machine, tick **Open the last project at launch**. Audio devices, the LTC input, OSC port, Dante and chase tuning belong to the Mac (Settings and the Record screen), not the project.

## Timeline (rehearsing songs out of order)

**Program** (**⌘1**) makes Understudy the clock instead of incoming LTC, and the decks follow it. Open the timeline in its own window with **⌘T**.

1. **Import CSV…:** a song list, one song per row: a name, a start timecode, and optionally an end or a Duration (`m:ss`). With a header row, columns are found by name (e.g. `SONG, Duration, LTC Start Point`). Starts can be `H:MM:SS` or full timecode. Songs with a blank or `n/a` start are skipped and listed after import. A song without an end or duration runs to the next song's start. An alphabetical list is laid out in timecode order.
2. **Audio:** **Find audio…** and pick the folder with the show's audio. Files are matched to songs by name, including subfolders, ignoring track numbers, BPM and the like, and the result lists any set songs still without audio. Or drop a file on a song, or right-click › Choose Audio…. Audio plays from the song's start timecode, and its waveform appears on the timeline.
3. **Set:** imported songs form the **Library**. Add tonight's songs to the **Set** with **+**. Only the set plays, and **Remove** takes a song off it (it stays in the library). An alphabetical sheet lands in the library; a list in running order becomes the set directly. Re-importing a corrected sheet keeps your set, its order and any audio.
4. **Order:** drag songs in the set. The timeline plays them back to back in that order. A lead-in before each song (2 s by default) gives the decks time to park on its footage.
   - **Setlists:** the Setlist menu saves the set under a name and switches between saved sets. **Order Set by Latest Take** (in the same menu) puts the set in the order the songs played in that take, and **Auto-Order After Each Take** does it every time a take ends.
5. **Play:** space plays and pauses. Click, drag or swipe to move the playhead; while playing it keeps playing from there (audio stays quiet until you stop moving). ← → step one frame, ⇧← → one second, ⌥← → one song. While paused the decks seek to the frame under the playhead; while playing they chase it.
   - **Loop:** **LOOP** under the timeline loops the song under the playhead (from its lead-in) or a section. **Drag along the ruler** above the current song to draw a section, press **I** at its start and **O** at its end, or select two markers › **Loop Between Them**. **L** turns the loop on and off; **×** on the loop (or **⇧L**) clears it. Outside the loop is dimmed, with its times and length on a label at the bottom. Sections are held on show code, so they stay with their song when you reorder the set. The decks re-cue at each loop.
   - **Stop after song:** stops at the end of each song, parked on the next song's lead-in, instead of rolling on. Play starts the next one.
   - **Downtime:** time between songs, before each lead-in (**LEAD-IN … · DOWN …** under the timeline). During downtime there's no code, no audio and no LTC out, like a show's changeovers, and the decks wait on the next song's first frame. The bar counts it down.
   - **Beat grid:** give a song a tempo (right-click it › **Tempo…**, or click **GRID** by the ruler); a BPM in its audio file's name is offered.
   - **Tempo from the audio:** Understudy listens to each song's audio (on this Mac, in the background, with the waveform) for its tempo and where the beats fall, checking each channel too so a click channel wins. Songs without a tempo of yours get it, marked **≈** (GRID ≈96); a BPM in the file name is trusted for the tempo, and the audio places the beats. **Tempo…** shows what it heard with **÷2**, **×2** and the other tempos it could be as one-click buttons. Beat one is a guess: **Set Downbeat at Playhead** fixes it. Tempos you type in or downbeats you set are never replaced. Checked against Apple Loops layered into songs: right first time in 70%, and the right tempo is one of the buttons in 80%; most misses are half, double or ¾ speed. Bar and beat lines appear as you zoom in, with bar numbers. **Set Downbeat at Playhead** lines the grid up with the music.
   - **Snap and quantize:** **SNAP 1/4** by GRID turns snapping on and picks the grid value (bar, 1/2, 1/4, 1/8, 1/16, 1/8 triplet): new and dragged markers land on the nearest line (a dragged selection moves together, keeping its spacing). **Q** quantizes the selected markers to that value; right-click › **Quantize** offers other values and **Halfway (50%)** to tighten without losing the feel. Songs without a tempo are left alone.
   - **Array markers:** right-click a marker › **Array From Here…**: a marker of its type on every bar, 1/2, 1/4, 1/8, 1/16 or 1/8 triplet after it, until the next marker, the song's end, the loop's end, or a count. An array shows as one row in the list (“45 × 1/4”) and as small ticks on the track. Clear it with its **×**, right-click › **Clear This Array**, or **Clear arrays** above the list. Markers placed by hand stay.
   - **Zoom:** zoomed in, every song is drawn at the same scale (the zoom is held in seconds), so markers pasted into a longer song look as far apart as they are. Pinch on the current song, ⌘= / ⌘−, or **+ / −** by its ruler (⌘0 for the whole song). The view follows the playhead, and the ruler goes down to single frames for placing markers exactly.
6. **Outputs:** Settings › Audio out picks the device and channels for song audio, and **Add another output for song audio** plays it to more devices at once (separate devices run on their own clocks, so they can drift a few milliseconds over a long song). **LTC out** generates timecode that follows the timeline, so disguise (or anything else) can chase the reordered playlist too.
   - **Timecode in the audio:** audio files are scanned for LTC. A timecode channel is muted on the music output, left off the waveform, lines the audio up, and plays to LTC out in place of the generator. Turn either off per song (right-click › Play Timecode Channel) or for all songs (Settings › Audio out › Use the track's own timecode).

**Recording names.** Record › Recording › File name sets how decks name their recordings. The default is `{deck}_{artist}_{date}_{time}` (e.g. `ME_1_RKS_2026-11-15_2015_0001.mov`). Tokens: `{deck}`, `{n}` (deck number), `{artist}`, `{show}` (setlist), `{date}`, `{day}` (Sun), `{time}` (2015), `{seconds}` (201530). The time is when Record is pressed.

**Markers.** Press 1–9 to drop a marker at the playhead (by default Choreo, Audio, Video, Notes, Lighting, Pyro, Automation; M repeats the last type). Make your own types with **Edit types…** beside the marker buttons (or Markers › Edit Marker Types…, ⌥⌘M): name, colour and order, saved with the project. Each marker shows as a square tag in its type's colour with its key number, and its label beside it. **Naming as you go:** after you drop a marker (a type button, 1–9 or M), its label opens in the list for typing: Return names it, Esc leaves it unnamed (Markers › **Name New Markers** turns this off). **Return** names the selected marker at any time. Markers from OSC don't ask. The list beside the song follows the playhead: the marker just passed has a red bar and stays in view as the song plays. Drag a marker to move it, click it to go there, right-click to rename or change its type. **Several at once:** ⌘-click or ⇧-click markers (on the track or in the list), or **Select all** in the list; then change their type, label them, move them by frames or seconds, loop between them or delete them together (right-click, or **Edit** above the list). **Undo:** ⌘Z / ⇧⌘Z undo and redo marker changes (adding, moving, pasting, quantizing, arraying, deleting, renaming), loops and tempos; Edit › Undo names the change. While you're typing in a field, they undo the typing. **Selecting several:** ⌘-click or ⇧-click markers on the track or in the list, **⇧-drag** across the song to box-select (⌘⇧-drag adds), or **⇧-click a marker type** to select all of its markers in the song; in the playlist, ⇧-click a run of songs or ⌘-click songs, then right-click to add or take them off the set, set one tempo for all, remove audio or delete them. **Copy and paste:** ⌘C copies the selected markers (arrays stay arrays), ⌘X cuts, ⌘V pastes them with the first at the playhead and the same spacing, in any song (snapped when Snap is on); ⌘A selects the song's markers. A readable list (timecode, type, label) goes on the clipboard too. Text fields keep their own copy and paste. Dragging any hit of an array moves the whole array; Move ▸ (right-click) moves by a beat, bar, frame or second. Dragging one of a selection on the timeline moves them all (select them in the list, then drag any one of their tags left or right); Esc goes back to one. **Send / Export** sends them to a grandMA3 (a sequence with a cue per marker plus a timecode show that fires them from LTC) or onto a disguise track (notes, sections or CUE tags, placed through the track's TC tags), or exports a CSV or a grandMA3 plugin. Set the addresses in **Settings › Show control**. On the MA3, add an OSC line (Menu › In & Out › OSC) with this Mac as destination, Mode UDP, the port and prefix from Settings, and Enable Input, Receive and Receive Command on.

**OSC control.** Understudy listens for OSC on UDP 9000 (Settings › Show control): `/understudy/play`, `/pause`, `/toggle`, `/stop`, `/song/next`, `/song/prev`, `/song <n>`, `/marker` (last type), `/marker/<1–7 or type> ["label"]`, `/marker/next`, `/marker/prev`. Point a Stream Deck (through Companion's OSC module) or an MA3 macro (`SendOSC`) at it.

**Dante out.** To send the timeline onto a Dante network, install and start Audinate's Dante Virtual Soundcard (licensed per Mac) with 4 or more channels, then turn on **Settings › Dante out**. Song audio goes out on DVS channels 1–2 (left, right) and timecode on 3; subscribe receivers to them in Dante Controller. DVS chooses the network port itself; set **Network port** to the same one and Understudy warns if it loses its link. While DVS isn't running, song audio and LTC use the Audio out settings.

**AES67 out (test).** Settings › AES67 out sends the timeline as a 3-channel AES67 stream (left, right, timecode) from the network port you pick, announced so Dante Controller lists it. Turn on AES67 mode on the receiving Dante device (Dante Controller › Device View › AES67 Config); it provides the PTP clock the stream locks to. Without a PTP master on the network the stream free-runs and Dante won't play it.

**Recording from the timeline.** Set **Show code** to **Song timeline** (Record › Timecode in, or tick **Show code for record** in the timeline window). In Stop and Record, show code then comes from the timeline instead of the LTC input. Press Record, then play the set: takes log against each song's own timecode with no cable. The song audio plays, and LTC out sends the same code to the decks' timecode inputs, disguise or another recorder. Play to code still chases the LTC input. For a quick test, **Record** under the timeline (⌥⌘R) does all of this in one step. If LTC out is off, it plays the songs' own timecode on the song-audio device's next channel (channel 3 when the music is on 1–2), with generated code between songs.

The footage comes from the selected take, so record a full run-through first.

## Video viewer and NDI

**View** (**⌘2**) plays the selected take's recordings (up to three decks) inside Understudy, locked to the timeline's timecode the same way the decks chase it: ME 1 large with the others beside it (click one to swap), or **Side by side**. The set and transport are underneath, so you can scrub and play from View too. The files come from your backup folder (back the take up first, ⌘B) and are copied into the project's `objects/VideoFile/<deck>/`. View › Video in a Window (⌥⌘V) puts the same pictures in their own window, for a second screen.

**NDI out** sends each video as its own NDI stream, *Understudy ME 1*, *Understudy ME 2*, *Understudy AUX 1*. Light mode (the default) scales files taller than 1080 lines down to 1080, keeping their shape; smaller files, 4:3, DCI and vertical go at their own size, never stretched or upscaled. *Full size* sends every file at its own size. The picture's aspect (pixel aspect included) and interlacing go out with it, HDR and wide-gamut files are converted to Rec.709, and frames go out as opaque BGRX (no alpha plane). What you see in View is drawn from the very frames NDI sends.

Every deck's source is there as soon as NDI is on, and stays up while NDI is on even if its deck goes offline or drops out of the take, so receivers bound to it by name keep it. A feed without video sends colour bars with its name, why there's no picture (e.g. *Can't play X (reason)*) and a TIME OF DAY clock; with no decks set up there's one source, *Understudy*. Between takes a feed keeps sending its last frame until the next file draws, so a screen never flashes bars, and every frame (bars too) goes out at the feed's own rate and size, so receivers don't renegotiate. The first time, macOS asks to let Understudy use the local network; allow it, or receivers won't see the sources. Understudy bundles NDI's library at build time: install the free [NDI SDK for Apple](https://ndi.video/for-developers/ndi-sdk/) (accepting its license) and `scripts/build-app.sh` copies `libndi.dylib` into the app. For CI builds, put a URL to that `libndi.dylib` in the `NDI_LIB_URL` secret. Without it, everything else works and NDI out says the library is missing.

### Playback LUT (log footage)

Understudy shows and sends recordings as they are: footage shot in a camera log curve stays flat and grey unless you choose a **Playback LUT**. It's a playback setting: it applies only to Understudy's viewer and NDI out. The deck, its outputs and its recordings are never changed. Next to NDI out, *Playback LUT* has a menu per deck (*ME 1 · None*):

- **None**: as recorded (the default).
- **Load LUT…**: any `.cube` file, e.g. your camera maker's log-to-Rec.709 LUT: 3D (up to 128³), 1D, or Resolve's shaper + 3D, with `DOMAIN_MIN`/`MAX` and `LUT_1D/3D_INPUT_RANGE` honoured. It's applied as written (a 1D LUT isn't squeezed into a cube). It's copied into the project's `objects/LUT/`, so the project carries it (a LUT chosen with no project open is copied in when you open or create one); LUTs already there are listed in the menu.

The LUT sees the file's own values: the decoded picture (video levels 0–1, as Resolve does for video-level clips), with wide-gamut and HDR files as recorded, not converted to Rec.709 first. Its output is taken as Rec.709. While a LUT is on, the picture says **LUT · name**; if it can't be applied (file missing or unreadable), it says **LUT MISSING · as recorded** in amber with the reason underneath, and the deck plays as recorded. Each NDI frame names the LUT in its metadata (`<understudy_playback lut="name"/>`, `lut="none"`, or `lut_missing="name"`) so receivers can tell.

Playback LUTs are saved in the project's playback settings (not with the decks), by feed name (*ME 1*, the same name as the deck's NDI source and its `objects/VideoFile/` folder). Projects saved by a pre-release build that kept the LUT on the deck are moved over when opened. The LUT runs on the GPU (Core Image, in the viewer's video composition). Changing the LUT while playing doesn't hitch; three decks with LUTs keep 1080p59.94 at full rate on Apple silicon, and a LUT puts frames out under one frame (about 15 ms) later than without.

NDI® is a registered trademark of Vizrt NDI AB.

## Running on a dedicated Mac

Understudy is meant to live on a Mac that stays at the rehearsal: a Mac mini on the show network is ideal. HyperDecks can't follow timecode in playback on their own, so a computer has to run it. In **Settings › Show machine**:

- **Keep this Mac awake** (on by default). The app also always opts out of App Nap, so its timing isn't throttled when the window is hidden or the display sleeps.
- **Start at login and relaunch if it quits unexpectedly** registers a launch agent bundled in the app. macOS may ask you to approve it under System Settings › General › Login Items. A normal Quit isn't relaunched. Only the copy the agent starts (at login) is watched: a copy opened by hand isn't, and Settings says which you're running. On a dedicated show Mac, let it start at login.
- **After a restart, go back to Record or Play** (off by default). When it happens, the header says so until you dismiss it. Decks that kept recording through the restart are left alone.

Only one copy runs at a time: a second launch hands over to the running one.

On the Mac itself: System Settings › Energy › *Start up automatically after a power failure*, automatic login, and Screen Sharing so you can watch and drive it from your laptop. Put it on a small UPS, and give LTC its own USB audio interface (the Mac mini's headphone jack is output only).

## Network ports (a Mac on several networks)

A show Mac often has several ports: the show network, Dante, the internet, an NDI or video network. **Settings › Network** picks the port for each kind of traffic. *Automatic (system routing)*, the default, leaves it to macOS: traffic for a network goes out of the port on that network, the rest out of the top port in System Settings › Network.

| Traffic | What uses the port |
|---|---|
| **Deck control** | HyperDeck control (TCP 9993), finding decks (Bonjour and the subnet scan) and FTP backups. The same choice as **Assign decks › On:**. |
| **grandMA3** | OSC to the console (Send to grandMA3). |
| **disguise** | HTTP to Designer (Push to disguise, the track list). |
| **NDI** | NDI out (*Understudy ME n*) and NDI in for the Understudy recorder. |
| **OSC in** | The OSC control port listens only on this port (Companion, a console). |

Each picker lists the Mac's ports with their address and subnet (or *no link*). Under it, **Now** says where the traffic is going: `en8 · 10.0.0.5`, *system routing*, or why the chosen port isn't in use. A chosen port is used while it has a link and an IPv4 address; until then that traffic follows the system's routing rather than stopping, and **Now** says so in amber. Settings also warns when a deck, console or Designer address isn't on the chosen port's subnet (it's then reached only if that network has a router to it).

How it's applied: connections are pinned to the port's interface (Network.framework's `requiredInterface`, the equivalent of `IP_BOUND_IF`), so they can't leave by another port; FTP copies run curl with `--interface`. A deck that isn't recording reconnects through a newly chosen port at once; a recording deck keeps its connection and moves when it next reconnects. The status lines say which port is in use: OSC in's status, the grandMA3 and disguise messages, the NDI line in View, and Backup.

NDI chooses its network adapters only when it starts, from its config file. Understudy writes its own copy of your NDI config (from `~/.ndi/ndi-config.v1.json`, as NDI Access Manager saves it) with `adapters.allowed` set to the port's addresses, and points NDI at it for Understudy only, so other NDI apps and Access Manager's settings aren't changed. A new NDI port takes effect the next time Understudy opens; Settings says so until then. If the port's address changes (DHCP), reopen Understudy too.

Dante out and AES67 out keep their own **Network port** pickers on the Audio out tab.

## Backing up takes

**Backup** copies the selected take off every connected deck into a folder on the Mac, by FTP, which HyperDecks serve on port 21 with no login. Choose a folder inside Dropbox and Dropbox syncs the files.

- Files land in `<folder>/<date>/<deck name>/<clip>`.
- Decks copy in parallel. A file already there at full size is skipped. An interrupted copy resumes.
- Backup is blocked while recording, and pressing **Record** cancels a backup in progress. Copying off a deck while it records isn't safe.
- Clips are found by name in the deck's media folders (slots, cache, USB), up to three levels deep.

## NotchLC test clips

**Record › Transcode a Take to NotchLC…** turns the selected take's files (one per connected deck, from the project, the backup folder or the Understudy recorder) into NotchLC `.mov` files to load into disguise or another media server as test clips. The source files are only ever read.

- **What it needs:** NotchLC can only be encoded on a Mac through **Adobe Media Encoder** (Creative Cloud) with **Notch's free NotchLC plugin for Adobe**. Get the macOS installer from Notch's downloads page (notch.one/downloads), install it, and quit Media Encoder if it was open. The sheet says what's missing until both are there. FFmpeg only decodes NotchLC, and Notch's other encoders are Windows-only or need a paid licence: see [docs/NOTCHLC.md](docs/NOTCHLC.md).
- **How it runs:** Understudy opens Media Encoder (or uses the copy it opened earlier) and leaves it open, with a small watcher script inside it. Files are encoded one at a time in the background, with progress per file and **Cancel**, which stops Media Encoder's queue. If you opened Media Encoder yourself, quit it first so Understudy can start it with the watcher. If Media Encoder is busy with its own queue, the file fails with that message: let the queue finish, then transcode again.
- **Where files go:** into a `NotchLC` folder beside the project's media for that deck (`objects/VideoFile/<deck>/NotchLC/`), or beside each file when no project is open, or into `<folder>/<deck>/` if you choose a folder. Each file is named like its source (`PGM_0003.mov`). A file that's already there is skipped (files only appear under their name once complete), so delete it to transcode again.
- **Timecode and rate:** the frame rate and size follow the source. Notch's exporter doesn't write timecode, so Understudy copies the encoded file into place with the source's QuickTime timecode track added (no re-encode).
- **Quality:** the NotchLC format's defaults. For another quality, save a preset in Media Encoder (Preset Browser → **+** → Create Encoding Preset, Format: NotchLC) and choose its `.epr` under **Preset**.
- Blocked while recording (the files are still being written). Media Encoder writes each encode to a short path in the temporary folder first: Notch's plugin (1.4.3) crashes Media Encoder when the output path is long, as paths inside Dropbox projects often are. That needs room on the startup disk for the largest file.

## Understudy recorder (no HyperDeck)

When a deck isn't there, a slot can record on the Mac instead: in **Assign decks**, switch the slot from **HYPERDECK** to **RECORDER**, choose a source and a codec, and Apply. It's a stand-in, not a replacement: it costs CPU, GPU and disk on the Mac that's also running the show, so use it in a pinch.

- **Sources:** any capture device macOS sees as a camera (capture cards with macOS drivers, webcams, Continuity Camera; the list the confidence monitor uses), any NDI source on the network (needs the NDI runtime or SDK, as for NDI out; this Mac's own Understudy outputs aren't offered, and are refused if a slot names one, since they're the decks' footage through the Playback LUT), or a **Test pattern** made on the Mac for checking the encoder and disk with no hardware. The recorder keeps the source's own size, frame rate and scan; the rate must be a broadcast rate (23.976–60).
- **Codecs:** H.264 or H.265 on the Mac's hardware encoder (about 20 and 12 Mb/s at 1080p29.97), or ProRes 422 Proxy / 422 (about 45 and 147 Mb/s), on the ProRes engine where the Mac has one (M1 Pro/Max/Ultra and later) and in software elsewhere; the menu marks software encoders and the deck row warns while one is in use.
- **Record and Stop** start and stop it with the HyperDecks, in either record mode. **Continuous**: it records from REC to STOP and Understudy logs show code against the take, as for a deck. **Only while code runs**: it records while show code rolls, a new take each run, like a deck's timecode-run trigger.
- **Colour and fields:** the recorder writes the picture as it arrives (it never applies a LUT: the viewer's and NDI out's Playback LUTs don't reach recordings) and tags the file with what it is. Capture devices' own colour tags are kept (HDR ones too); NDI and untagged pictures are Rec. 709 at 720 lines and up and BT.601 below, as NDI defines it. Interlaced sources (1080i, 576i, 480i) stay interlaced: ProRes files are marked as fields with the right field order and named like a deck's (`1080i5994`); H.264/H.265 code progressive frames, so the row says to use ProRes to keep fields. For ProRes, a capture device is read in 4:2:2, and in 10-bit when it sends 10-bit; H.264/H.265 read 4:2:0. A source with alpha is recorded without it, and the row says so.
- **Timecode:** each file gets a QuickTime timecode track stamped with show code at the first frame (the time of day if there's no show code, reading the clock at 23.976 and non-drop 29.97/59.94 too), counting drop-frame when show code does, at the video rate or its LTC rate as Settings' deck timecode option says. Files are named like a deck's clips, `<record name>_0001.mov`, and takes list, map and play back in View exactly like a deck's.
- **Where files go:** into the project's `objects/VideoFile/<deck>/` when a project is open (where View looks first), otherwise the backup folder's `<date>/<deck>/`, otherwise `~/Movies/Understudy/<deck>/`. Backup (⌘B) skips recorder slots: their files are on the Mac already. Files are written in fragments every 4 s, so a crash or power cut leaves a file that plays up to the last one.
- **Status:** the slot's row shows the input, data rate, frames dropped and disk time left, with warnings in plain words: NO SIGNAL, *n* FRAMES DROPPED, ENCODER OR DISK FALLING BEHIND, DISK: *n* MIN LEFT (amber under 10 minutes, red under 2), INTERLACED SOURCE RECORDED AS PROGRESSIVE, SOURCE ALPHA NOT RECORDED, SOFTWARE ENCODER. The Input row shows the source's size, rate, scan and pixel format (e.g. `1920×1080i 29.97 · 2vuy`). A slot with no frame for a moment holds the previous picture so the file stays constant frame rate; each held frame counts as dropped.
- **Limits of this first version:** video only (no audio track); NDI is received 8-bit (UYVY, or BGRA with alpha); frames are stamped when they arrive, so NDI's network delay (typically a frame or two) isn't taken off, and a capture device's delay is whatever its driver reports; a capture device can't be open in the recorder and the confidence monitor at once; another Mac's Understudy NDI out can still be recorded, and carries that Mac's Playback LUT; the source is open the whole time the slot is in use (a webcam's light stays on); a source that changes size mid-take stops the take; the recorder has no output, so Play to code doesn't chase it (the View screen plays its files).

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

HyperDecks can't send pictures over the network, so for real pictures feed a **quad-split multiviewer** of the four deck outputs (e.g. Blackmagic MultiView 4, or a switcher/disguise multiview) into a **capture device the Mac sees as a camera**: a USB/UVC HDMI or SDI capture box, an ATEM Mini's webcam out, or a Web Presenter. Turn it on in **Record › Playback › Confidence monitor**, pick the device, and say which quarter is which deck (or use *One deck* for a full-frame feed).

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

1. Open **Record › Timecode in** (`⌘3`) and pick the audio interface. It lists that device's input channels, by the device's own channel names, each with a live level meter. Click the one carrying LTC; it's marked **LTC** once code decodes. The show timecode rate is detected automatically (see below); you can fix it instead if you prefer. The main window's footer keeps a meter on the LTC channel.
2. Assign the decks. Pick the network to look on (**Network › On:**, e.g. the Ethernet adapter on the show network rather than Wi-Fi). Understudy looks for HyperDecks there: by Bonjour, and by asking every address on the Mac's subnets on port 9993, keeping only those that answer like a HyperDeck. They're listed under **Network**. Use **Assign** on a row, the **▾** next to a deck's address, or **Fill empty slots**. You can still type an address and press return. The first scan makes macOS ask for local network access; allow it, then **Find decks** again. Decks already connected are never probed, so a deck in use never gets a second client.
3. Check that each deck reads **Reference: LOCKED**.

## Operating

- **Record** (⇧⌘R, or Record on the Record screen) before the run. Each recording deck reads **● REC**, and the strip at the top says **Recording** on every screen.
- **Stop** (⇧⌘.), **Play to code** (⇧⌘P), **Follow Program** (⇧⌘F) or going to Program or View after the run ends the take; leaving Record always asks first. Pressing the current one again does nothing.
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
4. **Deck timecode base.** At 2160p59.94, check whether the deck reports display timecode frames 0–59 or 0–29. The default assumes 0–59. If your deck reports 0–29, turn off *Deck timecode counts at video rate* in Record › Playback › Advanced.
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
./scripts/network-harness.sh   # pins deck control, discovery, OSC in/out, disguise HTTP, curl and NDI to lo0 and en0 against stand-ins on 127.0.0.1 and 10.255.255.1; checks where the bytes go (temp store)
./scripts/notchlc-harness.sh   # transcodes generated clips through Media Encoder + the NotchLC plugin; checks codec, frames, rate, timecode, decodes them back, and Cancel (temp store; needs AME and the plugin)
./scripts/recorder-harness.sh  # records from NDI loopbacks (BGRA, UYVY, SD interlaced), generated and 10-bit frames; checks frames, timecode, colour and field tags, decoded colours (temp store)
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
