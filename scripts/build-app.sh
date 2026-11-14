#!/usr/bin/env bash
# Builds an ad-hoc signed Understudy.app and a zip in dist/.
# Universal (arm64 + x86_64) with full Xcode; this Mac's architecture with only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
    echo "Full Xcode not found: building for $(uname -m) only."
    ARCHS=()
else
    ARCHS=(--arch arm64 --arch x86_64)
fi

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

APP="dist/Understudy.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Understudy" "$APP/Contents/MacOS/Understudy"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"
# Login agent (Settings › Show machine): starts Understudy at login, relaunches it after a crash.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/com.shdwbx.understudy.agent.plist "$APP/Contents/Library/LaunchAgents/"
plutil -lint -s "$APP/Contents/Info.plist" "$APP/Contents/Library/LaunchAgents/com.shdwbx.understudy.agent.plist"

codesign --force --deep --sign - "$APP"
(cd dist && ditto -c -k --keepParent Understudy.app "Understudy-$VERSION-macos.zip")

echo "Built $APP ($VERSION, build $BUILD)"
