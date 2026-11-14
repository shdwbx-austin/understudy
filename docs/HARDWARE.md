# Recommended hardware: 3 or 4 records at 2160p59.94

What to buy to run Understudy with three or four camera feeds, each recorded and played back at UHD 2160p59.94 (or 2160p60) over 12G-SDI, with show LTC from the timecode system.

Specs are from Blackmagic's and Apple's pages as of 14 November 2026; figures marked **est.** are estimates. Sources are at the end.

## The short version

| | 3 records | 4 records |
|---|---|---|
| Decks | 3 × HyperDeck Studio 4K Pro | 4 × HyperDeck Studio 4K Pro |
| Recording media | 6 × 2 TB SATA SSD (two per deck) | 8 × 2 TB SATA SSD |
| Codec | ProRes 422, 2160p59.94 | same |
| Record time per deck | ~7.5 h (two 2 TB SSDs, spilling from one to the other) | same |
| Reference | Blackmagic Mini Converter Sync Generator, tri-level, or house sync | same |
| Control Mac | Mac mini M6, 16 GB / 256 GB | same |
| LTC into the Mac | Focusrite Scarlett Solo 4th Gen (one input) or a 2-input interface if you use a separate playback LTC | same |
| Confidence monitor (optional) | MultiView 4 HD + USB SDI capture (one quarter unused) | same, all four quarters |
| Backup of one 1-hour run (ProRes 422) | 1.6 TB | 2.1 TB |

Use one deck per camera. The HyperDeck Extreme 8K HDR has four SDI inputs, but in 4×SDI mode it records into separate channel folders and plays them back one after another, not as four synced outputs, so it can't stand in for four decks (see the README).

## 1. Decks: HyperDeck Studio 4K Pro

| | Studio 4K Pro (recommended) | Extreme 4K HDR | Shuttle 4K Pro |
|---|---|---|---|
| 2160p60 record and play | Yes, 12G-SDI | Yes, 12G-SDI | Yes, 12G-SDI |
| SDI | 1 in, 2 × 12G out, monitor out | 1 in, 2 × 12G out, 3G monitor out | 1 in, loop, 2 out, monitor out |
| Reference in | Tri-sync or black burst | Tri-sync or black burst | Shared with timecode on one BNC |
| Timecode | XLR in and out | XLR in and out | No XLR timecode |
| Media | 2 × 2.5" SSD, 2 × SD, USB-C | 2 × CFast 2.0, USB-C, optional M.2 cache | 1 × SD, USB-C, M.2 cache |
| Ethernet | 10G | 10G | 10G |
| Power | Two internal AC supplies, plus 12 V XLR | One internal AC, plus 12 V XLR | 12 V DC barrel only |
| Size | 1 RU | 3 RU half rack | Desktop |

**Why the Studio 4K Pro:** it has two internal power supplies on IEC, takes cheap SATA SSDs, and is 1 RU. It's also the deck Understudy has been built and tested against. The Shuttle 4K Pro is cheaper, but it has a single DC barrel and one SD slot, which isn't the right risk for a show. The Extreme costs more and gains nothing for this job.

**Not suitable:** the Shuttle HD (no SDI, HD only) and the Studio HD Pro, HD Plus and HD Mini (2160p30 at most).

## 2. Codec and media

**Record ProRes 422.** It is intra-frame, so decks cue and re-lock to code instantly when chasing. Long-GOP H.265 is far smaller but slower to cue and seek, which is what Understudy does on every jump in show code. ProRes 422 HQ is only worth it if the recordings are used for more than rehearsal review.

| Codec, 2160p60 | Data rate | Per deck, per hour | 3 decks / h | 4 decks / h |
|---|---|---|---|---|
| ProRes 422 HQ | 1,768 Mb/s | 795 GB | 2.4 TB | 3.2 TB |
| **ProRes 422** | **1,178 Mb/s** | **530 GB** | **1.6 TB** | **2.1 TB** |
| ProRes LT | 821 Mb/s | 369 GB | 1.1 TB | 1.5 TB |
| H.265 High (measured, not official) | ~70–100 Mb/s | ~32–45 GB | ~135 GB | ~180 GB |

(ProRes 2160p59.94 is about 0.1% below these 60p figures.)

**Media per deck: two 2 TB 2.5" SATA SSDs**, on Blackmagic's qualified list. The current manual lists the Samsung 860 PRO and 870 EVO, 250 GB–2 TB. Turn on spill to the second SSD in Understudy's deck Setup. That gives about 3.8 h per SSD, or ~7.5 h per deck, before anything needs clearing. Understudy shows the media time left on every deck and warns before it runs out.

**Avoid SD cards for records.** 2160p60 needs UHS-II cards writing faster than 220 MB/s, and a 256 GB card holds only about 19 minutes of ProRes 422 HQ.

## 3. Reference and timecode

**Reference.** Lock every deck to the same sync as the switcher and disguise. Use house sync if the venue has it. If not, use a **Blackmagic Mini Converter Sync Generator**: 6 outputs, tri-level or black burst. The HyperDecks take tri-sync or black burst. Locking a 2160p59.94 deck from 1080i59.94 tri-level is standard practice, but Blackmagic's pages don't say it in so many words, so confirm the deck shows reference locked on the bench (Understudy shows REFERENCE per deck).

**Show LTC into the Mac.** The Mac needs show timecode. The decks don't, because they record with their own clock and Understudy maps show code onto each take.
- **One LTC source:** Focusrite Scarlett Solo 4th Gen. It is class compliant, so it needs no driver; use its line input.
- **Separate show and playback LTC** (Settings › Timecode input): use an interface with two line inputs, such as a Scarlett 2i2, or two interfaces.
- Feed it from an LTC distribution output, not a split cable off another device's input.

**Optional regenerator.** If the show's LTC comes from far away or is flaky, put a jam-sync box in line, for example the **Tentacle Sync E mkII**: under one frame of drift in 24 hours. Understudy already freewheels through short dropouts (2 s by default), so this is a nice-to-have.

## 4. Video routing

Each feed runs **camera / switcher output → HyperDeck SDI in → HyperDeck 12G SDI out → disguise capture input**. In Stop the deck passes its input through, so disguise sees the live feed. In Play to code disguise sees the deck playing back.

- **disguise:** check that the server has one 12G-SDI capture input per deck, set to 2160p59.94: three or four inputs.
- **The decks' second 12G output** is free for a monitor or a backup path.
- **Distribution amps**, if a feed also has to go elsewhere: **Teranex Mini SDI Distribution 12G**, with 8 × 12G outputs up to 2160p60. Don't use the Mini Converter SDI Distribution 4K: it is 6G and stops at 2160p30.
- **Cable:** 12G-rated coax, with short runs. For long runs use fibre or a reclocking DA.

## 5. Confidence monitor (optional)

No Blackmagic MultiView accepts 2160p60 inputs: the MultiView 4 and 16 stop at 2160p30. Use each deck's HD monitor output instead:

**Each deck's monitor out (HD, 3G) → Blackmagic MultiView 4 HD (3G inputs, HD out) → USB SDI capture into the Mac.**

- **Capture:** a Magewell USB Capture SDI Gen 2 (3G, up to 2048×1080) matches the MultiView 4 HD's output. Magewell says it needs no driver on Mac, but neither maker says "UVC" outright, so test the unit with Understudy before buying several.
- **Turn the monitor outputs' overlays off** if the deck allows it. A running timecode overlay would make a frozen picture look like it's moving.
- With three decks, the fourth quarter is simply unused.

## 6. Control Mac

**Mac mini M6, 16 GB / 256 GB.** Understudy is light: one audio input, a few TCP connections and, optionally, a small capture stream. The base model is plenty.

- It has 2.5 GbE built in, 3 × Thunderbolt 4, HDMI and two front USB-C ports.
- The **10 GbE option** is worth it only if you back up ProRes over the network (see below). It's a build-to-order option, so choose it when ordering.
- Run it as a show machine (Settings › Show machine): start at login, relaunch after a crash, keep awake.
- Give it its own monitor or the HDMI output of a KVM, and a UPS.

## 7. Network

- **3 decks:** a 5-port switch. **4 decks:** an 8-port switch. Either one holds the decks, the Mac and an uplink. Keep the deck network separate from show control if the venue allows it.
- **For ProRes backups:** a multi-gig/10 GbE switch, with the Mac on 10 GbE. Check the decks' 10G port type (RJ45 vs SFP+) against the switch before ordering.
- **For control only,** any gigabit switch is enough.

## 8. Backup sizing

These are times to copy one 1-hour run off all the decks by FTP. Practical speeds assumed: 1 GbE about 100 MB/s, 2.5 GbE about 250 MB/s (est.), 10 GbE about 800 MB/s with several decks copying in parallel. Each deck's own SSD read speed is a ceiling too.

| One 1-hour run | Size, 3 / 4 decks | 1 GbE | 2.5 GbE (built in) | 10 GbE |
|---|---|---|---|---|
| ProRes 422 HQ | 2.4 / 3.2 TB | 6.6 / 8.8 h | 2.7 / 3.5 h | 50 / 66 min |
| **ProRes 422** | **1.6 / 2.1 TB** | 4.4 / 5.9 h | 1.8 / 2.4 h | 33 / 44 min |
| H.265 High (est.) | ~135 / 180 GB | 23 / 30 min | ~9 / 12 min | ~3 / 4 min |

**Where backups go.** A day of ProRes runs is several terabytes, so back up to a **local Thunderbolt drive or RAID of 8–16 TB** on the Mac, not straight into a syncing Dropbox folder. Dropbox would then upload terabytes over the venue's internet: 2 TB over a 100 Mb/s uplink takes about 44 hours. Put only selects, or H.265 copies, into Dropbox.

## 9. Rack, power, spares

- **Rack:**
  - 3 or 4 RU for the decks;
  - 1 RU of mini-converter shelf for the sync generator, MultiView 4 HD and any Teranex DA;
  - 1 RU shelf for the Mac mini and audio interface.
  - About **6–7 RU** in all.
- **Power:**
  - Feed each Studio 4K Pro's two supplies from two circuits, or from a UPS and mains.
  - Put the Mac, switch and sync generator on a pure-sine UPS.
- **Spares:**
  - Strongly recommended: one spare deck (Understudy reassigns a slot in seconds) and two spare SSDs.
  - Also worth having: a spare LTC interface and a spare SDI cable for every length used.

## Parts list

| Item | 3 records | 4 records |
|---|---|---|
| HyperDeck Studio 4K Pro | 3 | 4 |
| Spare deck (recommended) | 1 | 1 |
| 2 TB SATA SSD (two per deck, plus two spares) | 8 | 10 |
| Mini Converter Sync Generator (skip with house sync) | 1 | 1 |
| Mac mini M6, 16 GB / 256 GB | 1 | 1 |
| Scarlett Solo 4th Gen (or a 2-input interface) | 1 | 1 |
| MultiView 4 HD (confidence, optional) | 1 | 1 |
| USB SDI capture (confidence, optional) | 1 | 1 |
| Teranex Mini SDI Distribution 12G (only if needed) | as needed | as needed |
| Switch, backup RAID, UPS, cables, rack shelves | 1 set | 1 set |

## Check on the bench before the show

1. Each deck records and plays 2160p59.94 ProRes 422 from both SSDs, with spill, while Understudy chases code.
2. REFERENCE reads locked on every deck from the sync you'll use.
3. disguise captures all inputs at 2160p59.94 with the decks in Stop (live) and in Play to code.
4. The capture device shows up in Understudy's confidence settings, and a black or frozen deck reads BLACK or STILL.
5. A one-hour backup completes over the network you'll use, in the time the table predicts.

## Sources

- HyperDeck Studio tech specs: <https://www.blackmagicdesign.com/products/hyperdeckstudio/techspecs/W-HYS-29>
- HyperDeck Extreme tech specs: <https://www.blackmagicdesign.com/products/hyperdeckextreme/techspecs/W-HYD-08>
- HyperDeck Shuttle tech specs: <https://www.blackmagicdesign.com/products/hyperdeckshuttle/techspecs>
- HyperDeck manual (qualified media), Feb 2026: <https://documents.blackmagicdesign.com/UserManuals/HyperDeckHDManual.pdf>
- Apple ProRes white paper (data rates): <https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf>
- H.265 rates, user measurements: <https://forum.blackmagicdesign.com/viewtopic.php?p=862276>
- Teranex Mini tech specs: <https://www.blackmagicdesign.com/products/teranexmini/techspecs>
- Mini Converters (Sync Generator, SDI Distribution 4K): <https://www.blackmagicdesign.com/products/miniconverters/techspecs/W-CONM-29>
- MultiView tech specs: <https://www.blackmagicdesign.com/products/multiview/techspecs>
- Mac mini specs: <https://www.apple.com/mac-mini/specs/>
- Tentacle Sync E: <https://tentaclesync.com/sync-e>
- Focusrite Scarlett Solo 4th Gen (retailer): <https://fullcompass.com/prod/623366-focusrite-scarlett-solo-4th-gen-2x2-usb-audio-interface-4th-generation>
