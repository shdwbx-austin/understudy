#!/usr/bin/env bash
# Runs the core tests. Works with full Xcode or with only the Command Line Tools,
# which ship Swift Testing but don't put it on the default search paths.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV_DIR="$(xcode-select -p)"
FLAGS=()
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
    FW="$DEV_DIR/Library/Developer/Frameworks"
    LIB="$DEV_DIR/Library/Developer/usr/lib"
    FLAGS=(-Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW"
           -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB")
fi

swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
