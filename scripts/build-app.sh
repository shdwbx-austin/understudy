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
# App icon, drawn by scripts/make-icon.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The update feed's public key (Sparkle EdDSA): from the environment (CI), else the repo file.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-$(cat Resources/sparkle-public-key.txt 2>/dev/null || true)}"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" -e "s#__SPARKLE_PUBLIC_KEY__#${SPARKLE_PUBLIC_KEY}#g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
# Sparkle (auto-updates), next to the app's code.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Understudy"
# Login agent (Settings › Show machine): starts Understudy at login, relaunches it after a crash.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/com.shdwbx.understudy.agent.plist "$APP/Contents/Library/LaunchAgents/"
plutil -lint -s "$APP/Contents/Info.plist" "$APP/Contents/Library/LaunchAgents/com.shdwbx.understudy.agent.plist"

# Signing: a Developer ID identity (SIGN_IDENTITY, set by CI) signs inside-out with the hardened
# runtime, as Sparkle documents for builds outside Xcode; otherwise ad-hoc for local use.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP"
else
    S="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }
    sign "$S/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$S/XPCServices/Downloader.xpc"
    sign "$S/Autoupdate"
    sign "$S/Updater.app"
    sign "$APP/Contents/Frameworks/Sparkle.framework"
    sign --entitlements Resources/Understudy.entitlements "$APP"
    codesign --verify --strict --deep "$APP"
fi
(cd dist && ditto -c -k --keepParent Understudy.app "Understudy-$VERSION-macos.zip")

echo "Built $APP ($VERSION, build $BUILD)"
