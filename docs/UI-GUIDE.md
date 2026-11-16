# How Understudy's UI was made

A guide to the design system, the screens and the way we built and checked them, so new
features look and behave like the rest. Code references are to `Sources/Understudy/Views/`.

## 1. What the UI is for

Understudy runs in a dark control room during rehearsals. The person using it is usually doing
something else at the same time. So the UI has to:

- **Read from across the room.** The show timecode and deck state are the biggest things on screen.
- **Say what's wrong in one word, in one colour.** Locked, Freewheel, No LTC, Lost, ● Rec.
- **Be hard to break mid-show.** Risky actions ask first, setup locks while recording, and edits
  are drafts until Apply.
- **Stay calm.** Setup lives in sheets and Settings, not on the show screen.

## 2. The brief

Shdwbx house style, after the Swiss/Swedish brief: simple, clean, elegant, nothing cringy.

- A strict grid, flush left, after Neue Grafik.
- Hairline rules instead of boxes and cards.
- One type family for words and numerals, and a mono for data.
- Colour is rare, and it always means something.
- The product name is written lowercase in headings: **understudy**.

## 3. Tokens (`Theme.swift`)

### Colour

| Token | Value | Means |
|---|---|---|
| `ink` | black | background |
| `paper` | #F4F5F5 | text, primary controls |
| `grey` | 56% white | secondary text, captions |
| `quiet` | 36% white | disabled, "nothing here" |
| `rule` | 20% white | hairlines |
| `fill` | 7% white | fields, selected rows, TimeBlocks |
| `lock` | green | timecode locked, deck chasing, "good" |
| `amber` | amber | warnings only (freewheel, low media, a setting to check) |
| `signal` | red | recording, alarms (a lost deck, missing code in Record/Play) |

Marker types bring their own colours (CuePoints' palette by default, editable per project). They
are the only decorative colour, and they still carry meaning: the type.

**Rule:** if something is coloured, it has to be telling you something. Normal levels are not amber,
and a connected deck is not green unless it's doing its job.

### Type

- **Neue Haas Grotesk** for words and numerals. The **Display** cut (`NHaasGroteskDSPro-55Rg/65Md/75Bd`)
  is used for 17 pt and up. The **Text** cut (`NHaasGroteskTXPro-55Rg`) is used below that, because
  Display crowds at small sizes. `Theme.grotesk(size, weight)` picks the cut.
- **Space Mono** for data: addresses, formats, captions, readouts. `Theme.mono(size, bold:)`.
- **Fallbacks:** Helvetica Neue and the system mono. The brand fonts are commercial, so they're
  never bundled. The UI has to hold up in the fallbacks too.
- **Captions** are UPPERCASE Space Mono, 9–10 pt, tracked 1.2 (`Label8`, section heads).
- **Timecode never jitters.** Haas has proportional figures only (a 1 is half the width of a 0) and
  ignores the tabular-figures feature. So timecode is set character by character in fixed cells
  (`TimecodeText`), and the hero clock is four fixed `TimeBlock`s.

### Grid

- **Margins:** 48 pt leading, 32 trailing. **Gutter:** 24. **Unit:** 8.
- **The show screen** is a 150 pt label column, then **four equal columns** (`ShowGrid`). Every
  edge lands on one of those lines.
- `ColumnGrid` is a custom `Layout`: its children sit left to right, each `.span(n)` columns wide,
  and all are as tall as the tallest, so columns line up from row to row.
- `GridRow` is one show-screen row: a `RowLabel` (small section number over a name) in the label
  column, content across the four columns, and a hairline above.

## 4. Components (`Theme.swift` and screens)

| Component | Use |
|---|---|
| `Rule` / `VRule` | hairlines: the only dividers |
| `SectionHead(index:title:)` | "03  DECKS ———" with optional trailing controls |
| `RowLabel` | the left-column label of a show-screen row |
| `Label8` | small uppercase caption over or beside a value |
| `TextButton` | the house button: uppercase mono text, underlined on hover, colour by meaning |
| `StatusDot` | filled = on, ring = off |
| `LevelMeter` | −60…0 dBFS; red only for clipping, grey when barely there |
| `TimecodeText` | timecode in fixed cells |
| `TimeBlock` / `ClockDigits` | the four hero blocks: label top-left, digits bottom-right, red outline on alarm |
| `DeckCard` | one deck row: big slot number, one status word, a small table of input, reference and media |
| `DeckChip` | a compact deck status for the Timeline workspace (wraps four to a row) |
| `MarkerChip` | marker type: number disc + name in its colour; click or press its key |
| `PlayheadLine` / `PlayheadTime` | the playhead, watching only the playhead (see §8) |
| `WaveformView` | a Canvas, one bar per point, `Equatable` so it only redraws when the peaks change |

Buttons with a filled background are rare: the selected mode, and the primary action on the
start window. Everything else is a `TextButton`.

## 5. The screens

### Show screen (`ContentView`)

From top to bottom:
- **Header.** The name and the line "Stands in for the cameras between run-throughs", then the
  four TimeBlocks across the columns, then one state word (Locked, Acquiring, Freewheel…) with
  the rate.
- **01 Mode.** Stop · Record · Play to code · Timeline, one column each (⌘1–4). The current mode
  is filled paper on ink.
- **02 Take.** Which recording plays back.
- **03 Decks.** Full-width rows. A lost deck turns its whole row red.
- **Footer.** The LTC input on the grid: device, level, backup, AWAKE, and the shdwbx mark.

The hero size is worked out from the space left once the decks fit: huge on a 1080p show
monitor, smaller on a laptop, and never pushing a deck below the fold on 1440×900.

### Timeline workspace (`TimelineWorkspace`)

In Timeline mode the show screen's big clock and Mode row give way to one bar
(`TimelineTopBar`): name and project, `ModeTabs`, and the timecode with its state on one line.
The playlist and timeline take the rest. The playlist collapses to a slim rail (⌃⌘S); its
actions live in one ··· menu rather than a row of text buttons.

- **Playlist** on the left. It sits on the grid (label column plus one column) unless a song name
  needs more: then it widens to fit the longest name, up to 45% of the window. It holds the
  Set, then the Library.
- **The set:** song blocks to scale, lead-ins shaded, numbers at each start, and marker ticks
  along the bottom edge.
- **The marker bar:** type chips plus **Send / Export**.
- **The current song** up close (ruler, waveform, markers with draggable handles, playhead),
  with the **marker list** beside it.
- **Transport, then take and deck chips,** then a one-line status message.

### Start window (`StartView`)

After CuePoints' start window:
- **Left:** the name, version and update status; the projects folder (Change…); "Open the last
  project at launch"; the shdwbx mark.
- **Right:** Recent Projects, with **Open…** and **+ New Project** at the bottom. New Project is the
  one filled button.

### Settings and sheets

- **Settings** holds the Mac's things only, in tabs: General · Timecode · Recording · Playback ·
  Audio out · Show control. Each tab is a grouped `Form` that leads with its show-critical
  setting; tuning that's normally automatic (chase) and features not in daily use (the
  confidence monitor) are folded under disclosures.
- **Show things live in the project** and are edited where they're used: Assign decks and marker
  types. Recording names are the exception: saved with the project, but edited in Settings ›
  Recording.
- **Sheets** are for setup: Assign decks, Backup, deck Setup, Marker types. They use the same
  ink background and hairlines.

## 6. Interaction rules

- **Safety:**
  - Re-pressing the current mode does nothing (it used to split takes).
  - Leaving Record asks first.
  - Deck assignment, projects and adding or removing decks are locked while recording.
  - Deck edits are a draft until Apply.
  - Anything that overwrites something elsewhere says exactly what before it runs: "This replaces
    Sequence 1001 and Timecode 101 on the console."
- **Keyboard:**

  | Keys | Does |
  |---|---|
  | ⌘1–4 | modes |
  | space | play/pause |
  | ← → | step a frame |
  | ⇧← → | step a second |
  | ⌥← → | previous/next song |
  | 1–9 | drop a marker of that type |
  | M | drop another marker of the last type |
  | [ ] | previous/next marker |
  | ⌘T | timeline window |
  | ⌘N / ⌘O / ⇧⌘W | new / open / close project |

  Unmodified keys are button key equivalents, so they never fire while typing in a text field.
- **Scrolling:**
  - A two-finger swipe, a mouse side wheel or Shift + wheel scrubs across the whole set.
  - The same gesture over the current song steps frame by frame.
  - `HorizontalScrollReader` is an `NSEvent` monitor that only takes horizontal scrolls, and
    `hitTest` returns nil so it never steals clicks.
- **Seeking while playing:** clicks, drags and swipes keep playing from the new spot.
  - Audio and LTC out stay silent while you move, and resume 0.25 s after you stop.
  - The decks are parked under the playhead while it moves, then picked up at once.
  - When paused, a scroll is a one-frame step.
- **Messages are sentences that say what to do,** for example: "Set the grandMA3's IP in
  Settings › Show control." They are not error codes. Show them in the one-line status area, not
  in alerts, unless a decision is needed.
- **Copy:**
  - Plain words: "Play to code", "Rec decks (dev)".
  - Menu paths are written with ›.
  - Captions are uppercase mono; everything else is sentence case.

## 7. How we built it

1. **Brief first.** Start from the Shdwbx brief (Swiss grid, Haas + Space Mono, #F4F5F5 on black)
   and the job (a control room).
2. **Tokens before screens.** Colours, type and the grid went into `Theme.swift`, and every view
   uses those tokens rather than raw values.
3. **Grid before content.** The 150 + 4×column grid and `ColumnGrid` came first. Screens were
   then laid on it row by row.
4. **One feature at a time, rendered every time.** After each change we rendered the real views
   offscreen and looked at the picture before moving on:
   - Host the view in an `NSHostingView` inside a borderless `NSWindow`, `layoutSubtreeIfNeeded()`,
     wait about 0.6 s, `cacheDisplay` → PNG.
   - Render at **1440×900** (a laptop) and **1920×1080** (a show monitor).
   - Use **real data**: the RKS26 song sheet, synthetic audio with real waveform shapes, and LTC
     on a channel.
   - Crop to the part that changed and check it closely (overlapping labels, truncation, alignment).
5. **Measure, don't guess.** For speed we timed the main thread's CPU per frame
   (`CLOCK_THREAD_CPUTIME_ID`), before and after, with 20 songs and waveforms. Wall-clock time
   included window-server waits and misled us.
6. **Test the behaviour, not just the look.** Harnesses drove the real models: OSC from an
   independent peer, scrubbing while playing, markers through the exports, projects
   created, closed and reopened.
7. **Then a strict build, the tests and a packaged app** before every commit.

### Rules for harnesses

- **Never touch the real store.** Always set `UNDERSTUDY_STORE` to a temp folder (and a temp
  projects folder). A harness that lost this once wrote test setlists into a real show.
- For the packaged app, isolate preferences with `CFFIXED_USER_HOME` as well.
- Don't drive real decks or consoles from a harness without saying so. Use `10.255.255.x` for
  stand-in decks, and a local UDP listener as a stand-in console.

## 8. Performance patterns

- **Fast-changing state is published on its own.** The playhead (`PlayheadClock`), the show clock
  text and meters (`Readout`) each have a small `ObservableObject`. Only the views that draw them
  observe them. Before this, every frame redrew the playlist, waveforms and deck rows. After it,
  the main thread's work per frame went from 7–8.5 ms to 2.8 ms.
- **Derived "current" values are published only when they change** (`currentIndex` changes at song
  boundaries, not every frame).
- **Expensive drawing** is a `Canvas`, made `Equatable` so SwiftUI can skip it.
- **Throttle device traffic, not the UI.** Deck seeks while paused go out at most every 60 ms,
  always ending on the latest position.

## 9. Pitfalls we hit (macOS 13 + SwiftUI)

- **Menus drop composite labels.** A `Menu` label that's an `HStack` shows only its first `Text`.
  Put captions beside the menu, and make its label just the value.
- **Lists render blank offscreen** unless they're hosted in a window. Render inside an `NSWindow`.
- **macOS 13 is missing some APIs:**
  - `onChange(of:)` must use the one-argument closure.
  - There's no `SettingsLink`: use `NSApp.sendAction(Selector(("showSettingsWindow:")), …)`.
  - There's no `dismissWindow`: close by scene id (`WindowFinder`).
- **Window scenes:** the first `Window` in `body` opens at launch, which is why the start window
  comes first.
- **Text near markers collides.** Labels are packed into lanes (a label moves up a lane when it
  would hit the previous one), up to three.
- **Strict concurrency.** Callbacks that cross threads (file copies, audio render) must be
  `@Sendable`. Audio render blocks are built `nonisolated`, with state behind a lock.

## 10. Checklist for a new piece of UI

- [ ] Uses `Theme` colours and fonts only; any colour on screen means something.
- [ ] Sits on the grid (label column + four columns), flush left, divided by `Rule`s.
- [ ] Data in Space Mono, words in Haas; timecode in fixed cells.
- [ ] Reads at a glance from across the room, or lives in a sheet or Settings if it's setup.
- [ ] Risky actions are locked while recording, are drafts until Apply, or ask first, naming what
      they replace.
- [ ] Messages say what to do, in a sentence.
- [ ] Doesn't observe anything that changes every frame unless it draws it.
- [ ] Rendered at 1440×900 and 1080p with real data, checked closely, in a temp store.
- [ ] Builds with `-strict-concurrency=complete` and runs on macOS 13.
- [ ] Machine settings go in Settings; show settings go in the project.
