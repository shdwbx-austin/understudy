# cam4prog

Record four broadcast MEs on HyperDecks, then play them back into the disguise capture inputs locked to show timecode — so you can program against real SDI between run-throughs, with no files to copy and no transcoding.

Shdwbx · Design and Creative Support

---

## What it does

| Mode | Decks | disguise sees |
| --- | --- | --- |
| **STOP** `⌘1` | Stopped, disarmed, in preview | Live ME (passes through the deck) |
| **REC ARM** `⌘2` | Armed to record whenever show LTC runs | Live ME |
| **PLAY TC** `⌘3` | Chase show LTC from the selected take | Recorded ME, in sync with code |

After a run-through, hit **PLAY TC**. The latest take is selected, and the decks follow code every time you roll it.

HyperDecks can't chase LTC natively. cam4prog reads the show LTC itself and handles each deck in four steps:

1. It parks the deck slightly ahead of incoming code (pre-roll).
2. It fires `play` when code reaches that point, early by the deck's start latency.
3. It watches the deck's timecode ten times a second.
4. It re-parks the deck if the deck drifts out of tolerance.

## Signal flow

```
ME n ─SDI─▶ HyperDeck n SDI IN        HyperDeck n SDI OUT ─SDI─▶ disguise capture n
Show LTC ─DA─▶ every HyperDeck TC IN (XLR)  +  Mac audio input
House ref ─DA─▶ every HyperDeck REF IN  +  disguise capture cards
Mac ─Ethernet─▶ switch ─▶ HyperDecks (static IPs)
```

For the show itself, put a router or bypass in front of the disguise inputs so a deck fault can't take an IMAG feed.

## Deck setup (once per deck)

- Give each deck a static IP on the same network as the Mac.
- Feed show LTC into **Timecode In**, and house ref into **Ref In**.
- Format SSDs. All four decks should use the same codec and the same video format.
- Everything else is set by cam4prog when you change mode: remote override, timecode input = external, record trigger, record prefix (deck name), preview/output, and timecode output = clip.

## App setup

1. Open **Settings** (`⌘,`). Pick the audio interface and channel carrying LTC, then set the show timecode rate.
2. Type each deck's IP into its card and press return. The dot goes green and the card shows the model.
3. Check that each card reads **REF LOCKED**.

## Operating

- **REC ARM** before the run. A card's border turns red while that deck records.
- **PLAY TC** after the run. Roll code (or let the show roll it), and each card goes WAITING → CUEING → ARMED → CHASING.
- **Δ** shows the measured deck error in LTC frames. If a deck sits consistently early or late, press **Calibrate** to fold that error into its play offset.
- **TAKE** lets you pick an older run. Takes are matched across decks by position (latest, second latest, and so on).
- **NO MEDIA AT TC** means code is outside the selected take. The deck holds until code comes back into range.

## First hardware test — what to verify

This build is unit-tested on the timecode, LTC, protocol and chase logic. It has not yet been run against decks. On the bench, confirm the following:

1. **Combined goto.** `goto: clip id: N clip: F` is accepted by your firmware. If it isn't, the app falls back to two separate commands, and the card will show the error once.
2. **Deck timecode base.** At 2160p59.94, check whether the deck reports display timecode frames 0–59 or 0–29. The default assumes 0–59. If your deck reports 0–29, turn off *Deck timecode counts at video rate* in Settings.
3. **Play latency.** Check Δ after a few rolls and calibrate.
4. **Pass-through.** In STOP / REC ARM, confirm the deck's SDI out passes the live input to disguise.
5. **Local network permission (macOS 15+).** On first launch, allow cam4prog when macOS asks.

## Build

Runs on macOS 13+. Building needs Swift 6 (Xcode 16 or its Command Line Tools); the universal app build needs full Xcode.

```sh
./scripts/test.sh           # core logic tests (Swift Testing; works without Xcode)
swift run Cam4Prog         # run unbundled while developing
./scripts/build-app.sh     # dist/cam4prog.app + zip (ad-hoc signed)
```

Pushing a tag like `v0.1.0` runs CI and attaches the zipped app to a GitHub release.

The first launch of an ad-hoc signed build needs right-click → **Open**.

## Layout

```
Sources/Cam4ProgCore   timecode math, LTC decoder/encoder, HyperDeck protocol, chase engine (pure, tested)
Sources/Cam4Prog       SwiftUI app, Core Audio LTC input, Network.framework deck client
Tests/                 XCTest for the core
scripts/build-app.sh   bundle + sign + zip
```
