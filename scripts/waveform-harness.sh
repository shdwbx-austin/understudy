#!/usr/bin/env bash
# Builds and runs the waveform harness (scripts/waveform-harness/main.swift): generates a test
# song, analyses it like the app does and renders its waveform at the timeline's zooms to PNGs;
# checks an analysis cached before the current waveform format is upgraded in place; and times
# drawing a 2-hour show. Always uses a temp store. Usage: scripts/waveform-harness.sh [out-folder]
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d -t understudy-waveform-harness)"
export UNDERSTUDY_STORE="$WORK/store"
OUT="${1:-$WORK/out}"
mkdir -p "$WORK/module" "$UNDERSTUDY_STORE" "$OUT"

echo "Building UnderstudyCore…"
swiftc -O -parse-as-library -module-name UnderstudyCore -emit-module -emit-module-path "$WORK/module/UnderstudyCore.swiftmodule" \
    -emit-library -static -o "$WORK/libUnderstudyCore.a" Sources/UnderstudyCore/*.swift
echo "Building the harness…"
swiftc -O -module-name WaveformHarness -I "$WORK/module" -L "$WORK" -lUnderstudyCore -o "$WORK/harness" \
    scripts/waveform-harness/main.swift scripts/waveform-harness/Render.swift \
    Sources/Understudy/WaveformLoader.swift Sources/Understudy/Views/WaveformView.swift
"$WORK/harness" "$OUT"
