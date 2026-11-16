#!/usr/bin/env bash
# Adds NDI to a published release, on this Mac (where the NDI SDK is installed).
#
#   scripts/release-add-ndi.sh v0.4.0            # update the release's files
#   scripts/release-add-ndi.sh v0.4.0 --dry-run  # build everything, upload nothing
#
# GitHub Actions builds the release (universal app, installer, update feed). This downloads that
# app, puts libndi from the NDI SDK into Contents/Frameworks, signs it again, rebuilds the
# installer, signs a new update feed with the Sparkle key in your keychain, and replaces the
# release's zip, pkg and appcast.xml. Run it once the tag's CI run has finished.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/release-add-ndi.sh vX.Y.Z [--dry-run]}"
DRY="${2:-}"
REPO="${REPO:-shdwbx-austin/understudy}"
VERSION="${TAG#v}"
NDI_LIB="${NDI_LIB:-/Library/NDI SDK for Apple/lib/macOS/libndi.dylib}"
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/sparkle/bin}"
GH="$(command -v gh || echo /opt/homebrew/bin/gh)"

[[ -f "$NDI_LIB" ]] || { echo "NDI SDK not found at $NDI_LIB"; exit 1; }
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || { echo "Sparkle tools not found in $SPARKLE_BIN (see docs/RELEASING.md)"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ZIP="Understudy-$VERSION-macos.zip"

echo "Downloading $TAG's app…"
"$GH" release download "$TAG" --repo "$REPO" --pattern "$ZIP" --dir "$WORK"
ditto -x -k "$WORK/$ZIP" "$WORK/app"
APP="$WORK/app/Understudy.app"
[[ -d "$APP" ]] || { echo "No Understudy.app in $ZIP"; exit 1; }
SHORT="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
[[ "$SHORT" == "$VERSION" ]] || { echo "The release's app is $SHORT, not $VERSION"; exit 1; }

NDI_VERSION="$(strings "$NDI_LIB" | grep -m1 'NDI SDK APPLE' | awk '{print $NF}')" || true
echo "Adding NDI ${NDI_VERSION:-(unknown version)}…"
cp "$NDI_LIB" "$APP/Contents/Frameworks/libndi.dylib"
install_name_tool -id "@rpath/libndi.dylib" "$APP/Contents/Frameworks/libndi.dylib" 2>/dev/null || true

# Sign again. A Developer ID in this keychain (SIGN_IDENTITY) signs properly; otherwise ad hoc,
# as the release was built.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP"
else
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/libndi.dylib"
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" --entitlements Resources/Understudy.entitlements "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "Packing…"
mkdir -p "$WORK/out"
(cd "$WORK/app" && ditto -c -k --keepParent Understudy.app "$WORK/out/$ZIP")
# The installer, from this app (build-installer.sh packs dist/Understudy.app).
rm -rf dist && mkdir -p dist && ditto "$APP" dist/Understudy.app
VERSION="$VERSION" ./scripts/build-installer.sh >/dev/null
cp "dist/Understudy-$VERSION.pkg" "$WORK/out/"

echo "Signing the update feed (your Sparkle key; macOS may ask to allow keychain access)…"
mkdir -p "$WORK/feed"
cp "$WORK/out/$ZIP" "$WORK/feed/"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO/releases/tag/$TAG" "$WORK/feed" >/dev/null
cp "$WORK/feed/appcast.xml" "$WORK/out/"
SIG="$(grep -oE 'sparkle:edSignature="[^"]*"' "$WORK/out/appcast.xml" | head -1 | cut -d'"' -f2)"
if "$SPARKLE_BIN/sign_update" --verify "$WORK/out/$ZIP" "$SIG" 2>&1 | grep -qi error; then
    echo "The new feed's signature doesn't verify: stopping."; exit 1
fi
echo "Feed signature verifies."

ls -la "$WORK/out" | awk 'NR>1 {print "  " $5 "  " $9}'
if [[ "$DRY" == "--dry-run" ]]; then
    mkdir -p dist/release-$VERSION && cp "$WORK/out/"* "dist/release-$VERSION/"
    echo "Dry run: nothing uploaded. Files kept in dist/release-$VERSION/."
    exit 0
fi
echo "Replacing $TAG's files…"
"$GH" release upload "$TAG" --repo "$REPO" --clobber "$WORK/out/$ZIP" "$WORK/out/Understudy-$VERSION.pkg" "$WORK/out/appcast.xml"
echo "Done: $TAG now includes NDI."
