#!/usr/bin/env bash
# Runs the grandMA3 export's Lua (OSC lines and plugin) against a mock console
# (scripts/ma3-harness/console.lua): builds what it should, and never deletes or overwrites what
# isn't Understudy's. Needs `lua` (brew install lua). Never talks to a real console.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v lua >/dev/null || { echo "Needs lua: brew install lua"; exit 2; }
WORK="$(mktemp -d -t understudy-ma3-harness)"
export UNDERSTUDY_STORE="$WORK/store"
mkdir -p "$WORK/module" "$UNDERSTUDY_STORE"

echo "Building UnderstudyCore…"
swiftc -O -parse-as-library -module-name UnderstudyCore -emit-module -emit-module-path "$WORK/module/UnderstudyCore.swiftmodule" \
    -emit-library -static -o "$WORK/libUnderstudyCore.a" Sources/UnderstudyCore/*.swift
swiftc -O -I "$WORK/module" -L "$WORK" -lUnderstudyCore -o "$WORK/gen" scripts/ma3-harness/main.swift
"$WORK/gen" "$WORK/plans.lua"
lua scripts/ma3-harness/console.lua "$WORK/plans.lua"
