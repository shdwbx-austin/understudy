#!/usr/bin/env bash
# Builds a universal, ad-hoc signed cam4prog.app and a zip in dist/.
# Requires Xcode (not just the Command Line Tools) for the universal build.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="dist/cam4prog.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Cam4Prog" "$APP/Contents/MacOS/Cam4Prog"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
(cd dist && ditto -c -k --keepParent cam4prog.app "cam4prog-$VERSION-macos.zip")

echo "Built $APP ($VERSION, build $BUILD)"
