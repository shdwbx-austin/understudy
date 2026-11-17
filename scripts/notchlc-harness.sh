#!/usr/bin/env bash
# End-to-end check of "Transcode to NotchLC": generates test clips, transcodes them through Adobe
# Media Encoder + Notch's NotchLC plugin with the app's own driver (MediaEncoder, NotchLCFinish),
# and checks every result:
#   - codec is NotchLC ('nclc'), frame count, frame rate and start timecode match the source;
#   - it decodes: Media Encoder (Notch's importer) turns the NotchLC file back into H.264, and every
#     frame's burned-in counter must read 0, 1, 2, … with none dropped or repeated;
#   - Cancel stops Media Encoder mid-encode and leaves no file.
# Needs Adobe Media Encoder and the NotchLC plugin. Uses a temp store; quits Media Encoder at the
# end only if this script started it.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d -t understudy-notchlc-harness)"
export UNDERSTUDY_STORE="$WORK/store"
BIN="$WORK/bin"
# A long destination with spaces and non-ASCII, like a project inside Dropbox.
DEST="$WORK/out/ShdwBX Studios Dropbox/Shows/Test Show — Café Tour 2026/Test Show.understudy/objects/VideoFile/ME 1/NotchLC"
mkdir -p "$BIN" "$UNDERSTUDY_STORE" "$DEST" "$WORK/module"

echo "Building…"
swiftc -O -parse-as-library -module-name UnderstudyCore -emit-module -emit-module-path "$WORK/module/UnderstudyCore.swiftmodule" \
    -emit-library -static -o "$WORK/libUnderstudyCore.a" Sources/UnderstudyCore/*.swift
swiftc -O -module-name NotchLCHarness -I "$WORK/module" -L "$WORK" -lUnderstudyCore -o "$BIN/notchlc-harness" \
    scripts/notchlc-harness/main.swift Sources/Understudy/MediaEncoder.swift Sources/Understudy/NotchLCFinish.swift
for tool in make-test-clip inspect-clip check-frames; do
    swiftc -O -o "$BIN/$tool" "scripts/$tool.swift" 2>/dev/null
done

AME_WAS_OPEN=0
pgrep -f "MacOS/Adobe Media Encoder" >/dev/null && AME_WAS_OPEN=1
PASS=0; FAIL=0
check() {  # name, actual, expected
    if [[ "$2" == "$3" ]]; then echo "  ok    $1: $2"; PASS=$((PASS + 1))
    else echo "  FAIL  $1: got $2, expected $3"; FAIL=$((FAIL + 1)); fi
}
field() { python3 -c "import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])" "$1" "$2"; }
H264="$(ls "/Applications/"Adobe\ Media\ Encoder\ */Adobe\ Media\ Encoder\ *.app/Contents/MediaIO/systempresets/4E49434B_48323634/"00 - Match Source - High bitrate.epr" | tail -1)"

# The second source sits under a non-ASCII path, as a show folder might.
for spec in "A001_0001 100 25 01:00:00:00 src" "B002_0007 120 29.97 10:59:58:00 src — Café" "C003_0002 60 59.94 23:59:59:00 src"; do
    IFS=' ' read -r name frames fps start srcdir <<<"$spec"
    echo "== $name: $frames frames at $fps, from $start (in '$srcdir')"
    mkdir -p "$WORK/$srcdir"
    src="$WORK/$srcdir/$name.mov"
    "$BIN/make-test-clip" "$src" "$frames" "$fps" "$start" 1280 720 >/dev/null
    out="$DEST/$name.mov"
    if "$BIN/notchlc-harness" "$UNDERSTUDY_STORE/MediaEncoder" "$src" "$out"; then
        info="$("$BIN/inspect-clip" "$out")"
        check "codec" "$(field "$info" codec)" "nclc"
        check "frames" "$(field "$info" frames)" "$frames"
        check "frame rate" "$(python3 -c "print(round(float('$(field "$info" fps)'), 2))")" "$(python3 -c "print(round(float('$fps'), 2))")"
        check "timecode" "$(field "$info" timecode)" "$start"
        # Notch's importer in Media Encoder can't open NotchLC files under non-ASCII paths (it
        # silently reads nothing), so decode a copy from a plain path.
        mkdir -p "$WORK/decode"
        cp "$out" "$WORK/decode/$name.mov"
        echo "   decoding through Media Encoder (Notch's importer) to H.264…"
        if "$BIN/notchlc-harness" "$UNDERSTUDY_STORE/MediaEncoder" "$WORK/decode/$name.mov" "$WORK/$name-decoded.mov" --preset "$H264" >/dev/null; then
            check "decoded frames" "$("$BIN/check-frames" "$WORK/$name-decoded.mov" "$frames" | cut -d' ' -f1)" "OK"
        else
            check "decode" "failed" "ok"
        fi
    else
        check "transcode" "failed" "ok"
    fi
done

echo "== Cancel mid-encode (3000 frames, 1080p)"
"$BIN/make-test-clip" "$WORK/long.mov" 3000 25 02:00:00:00 1920 1080 >/dev/null
result="$("$BIN/notchlc-harness" "$UNDERSTUDY_STORE/MediaEncoder" "$WORK/long.mov" "$DEST/long.mov" --cancel-after 4 | tail -1)"
check "cancel" "$result" "STOPPED"
check "no output after cancel" "$([[ -e "$DEST/long.mov" ]] && echo present || echo none)" "none"

if [[ $AME_WAS_OPEN == 0 ]]; then
    printf 'app.scheduleTask("app.quit()", 500, false);' > "$UNDERSTUDY_STORE/MediaEncoder/inbox/quit.tmp"
    mv "$UNDERSTUDY_STORE/MediaEncoder/inbox/quit.tmp" "$UNDERSTUDY_STORE/MediaEncoder/inbox/quit.jsx"
fi
echo
echo "$PASS passed, $FAIL failed. Files: $WORK"
[[ $FAIL == 0 ]]
