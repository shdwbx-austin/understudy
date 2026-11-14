# Changelog

## 0.2.0 — unreleased

- **Renamed from cam4prog to Understudy.** The bundle ID is unchanged, so saved settings and macOS permissions carry over. Saved take maps move to the new folder on first launch.
- **Recording no longer depends on show timecode.** In the new default mode, decks record from REC until STOP, stamped with their own clock. Understudy logs show LTC against each take as a timecode map, so dropouts and jumps no longer stop or break a recording.
- Playback looks show code up in the take's map: it holds at gaps, re-parks at jumps, and plays the latest pass of re-rolled code. Takes without a map play from clip timecode, as before.
- **Show timecode rate is detected automatically** from incoming LTC (23.976, 24, 25, 29.97 DF/NDF, 30), and playback follows it. A fixed rate is still available.
- LTC frames now reach the app strictly in order.
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
