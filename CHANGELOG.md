# Changelog

## 0.1.0 — first build

- Three modes: **STOP**, **REC ARM** (decks record on timecode run), **PLAY TC** (decks chase show LTC).
- LTC decoder reading any Core Audio input/channel, 23.976–30 fps, drop and non-drop.
- Up to four HyperDecks over the Ethernet protocol (TCP 9993), auto-reconnect.
- Chase: pre-roll cue, early play fire with per-deck offset, drift monitoring and automatic re-lock.
- Take picker matched by position across decks, follow-latest option.
- Calibrate button folds measured drift into each deck's play offset.
