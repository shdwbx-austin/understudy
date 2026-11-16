#!/usr/bin/env bash
# Builds dist/Understudy-<version>.pkg from dist/Understudy.app (run scripts/build-app.sh first).
# Installs to /Applications. Signed when INSTALLER_IDENTITY names a Developer ID Installer identity.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(cat VERSION)}"
APP="dist/Understudy.app"
[[ -d "$APP" ]] || { echo "Build the app first: scripts/build-app.sh"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/Applications" "$WORK/resources"
ditto "$APP" "$WORK/root/Applications/Understudy.app"
# Always /Applications (not wherever an older copy happens to be).
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" \
    --identifier com.shdwbx.understudy.app --version "$VERSION" \
    --scripts Resources/installer/scripts --install-location / \
    "$WORK/Understudy-component.pkg"
for f in welcome.html conclusion.html; do sed "s/__VERSION__/$VERSION/g" "Resources/installer/$f" > "$WORK/resources/$f"; done
sed "s/__VERSION__/$VERSION/g" Resources/installer/distribution.xml > "$WORK/distribution.xml"

OUT="dist/Understudy-$VERSION.pkg"
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
    productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" \
        --sign "$INSTALLER_IDENTITY" --timestamp "$OUT"
else
    productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" "$OUT"
fi
echo "Built $OUT"
