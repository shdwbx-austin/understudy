#!/usr/bin/env bash
# Builds and runs the network harness (scripts/network-harness/main.swift): checks that deck
# control, discovery probes, OSC in and out, disguise HTTP, curl and NDI leave through the chosen
# port, using lo0 and en0. Talks only to stand-ins on 127.0.0.1 and to 10.255.255.1 (nothing
# answers there). Always uses a temp store. Needs en0 with an IPv4 address and 127.0.0.1:9993 free.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d -t understudy-network-harness)"
export UNDERSTUDY_STORE="$WORK/store"
export UNDERSTUDY_LIBNDI="${UNDERSTUDY_LIBNDI:-/Library/NDI SDK for Apple/lib/macOS/libndi.dylib}"
mkdir -p "$WORK/module" "$UNDERSTUDY_STORE"
cp Sources/CNDI/include/cndi.h "$WORK/module/"
printf 'module CNDI {\n  header "cndi.h"\n  export *\n}\n' > "$WORK/module/module.modulemap"

echo "Building UnderstudyCore…"
swiftc -O -parse-as-library -module-name UnderstudyCore -emit-module -emit-module-path "$WORK/module/UnderstudyCore.swiftmodule" \
    -emit-library -static -o "$WORK/libUnderstudyCore.a" Sources/UnderstudyCore/*.swift
echo "Building the harness…"
swiftc -O -module-name NetworkHarness -I "$WORK/module" -L "$WORK" -lUnderstudyCore -o "$WORK/harness" \
    scripts/network-harness/main.swift scripts/network-harness/Stubs.swift \
    Sources/Understudy/NetworkPinning.swift Sources/Understudy/DeckDiscovery.swift Sources/Understudy/HyperDeckClient.swift \
    Sources/Understudy/ShowLink.swift Sources/Understudy/NDI.swift
"$WORK/harness"
