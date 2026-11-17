#!/usr/bin/env bash
# Builds and runs the recorder harness (scripts/recorder-harness/main.swift) against the
# recorder's engine sources. Always uses a temp store; needs the NDI SDK or runtime for the
# NDI loopback (UNDERSTUDY_LIBNDI, default: the NDI SDK for Apple).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d -t understudy-recorder-harness)"
export UNDERSTUDY_STORE="$WORK/store"
export UNDERSTUDY_LIBNDI="${UNDERSTUDY_LIBNDI:-/Library/NDI SDK for Apple/lib/macOS/libndi.dylib}"
OUT="${1:-$WORK/out}"
mkdir -p "$WORK/module" "$UNDERSTUDY_STORE" "$OUT"
cp Sources/CNDI/include/cndi.h "$WORK/module/"
printf 'module CNDI {\n  header "cndi.h"\n  export *\n}\n' > "$WORK/module/module.modulemap"

echo "Building UnderstudyCore…"
swiftc -O -parse-as-library -module-name UnderstudyCore -emit-module -emit-module-path "$WORK/module/UnderstudyCore.swiftmodule" \
    -emit-library -static -o "$WORK/libUnderstudyCore.a" Sources/UnderstudyCore/*.swift
echo "Building the harness…"
swiftc -O -module-name RecorderHarness -I "$WORK/module" -L "$WORK" -lUnderstudyCore -o "$WORK/harness" \
    scripts/recorder-harness/main.swift \
    Sources/Understudy/InternalRecorder.swift Sources/Understudy/NDIReceiver.swift Sources/Understudy/NDI.swift \
    Sources/Understudy/NDITestPattern.swift Sources/Understudy/ConfidenceMonitor.swift \
    Sources/Understudy/DeckController.swift Sources/Understudy/HyperDeckClient.swift Sources/Understudy/TakeMapStore.swift \
    Sources/Understudy/RecorderTakeStore.swift Sources/Understudy/RecorderBufferTags.swift \
    Sources/Understudy/NetworkPinning.swift Sources/Understudy/DeckDiscovery.swift \
    scripts/recorder-harness/DeckPath.swift scripts/recorder-harness/Pictures.swift scripts/recorder-harness/Stubs.swift
"$WORK/harness" "$OUT"
