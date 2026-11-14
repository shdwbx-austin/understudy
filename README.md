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

## App setup

1. Open **Settings** (`⌘,`) and pick the audio interface. Settings lists that device's input channels, by the device's own channel names, each with a live level meter. Click the one carrying LTC; it's marked **LTC** once code decodes. The show timecode rate is detected automatically (see below); you can fix it instead if you prefer. The main window's footer keeps a meter on the LTC channel.
2. Assign the decks. Understudy looks for HyperDecks on the local network: by Bonjour, and by asking every address on the Mac's subnets on port 9993, keeping only those that answer like a HyperDeck. They're listed under **Network**. Use **Assign** on a row, the **▾** next to a deck's address, or **Fill empty slots**. You can still type an address and press return. The first scan makes macOS ask for local network access; allow it, then **Find decks** again. Decks already connected are never probed, so a deck in use never gets a second client.
3. Check that each deck reads **Reference: LOCKED**.

## Operating

- **REC** before the run. A card's border turns red while that deck records, and the card reads **LOGGING SHOW CODE** (or **WAITING FOR LTC** while code is absent).
- **STOP** or **PLAY TC** after the run ends the take.
- **PLAY TC**: roll code (or let the show roll it), and each card goes WAITING → CUEING → ARMED → CHASING.
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
