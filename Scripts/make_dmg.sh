#!/usr/bin/env bash
# Build a universal Mac Clean.app and wrap it in a drag-to-Applications disk image.
# Adapted from App Clean's Scripts/make_dmg.sh; the staging folder stays inside build/.
# Usage: Scripts/make_dmg.sh        ->  build/MacClean-<version>.dmg (and its .sha256)
set -euo pipefail

cd "$(dirname "$0")/.."

Scripts/build_app.sh release universal

APP="build/Mac Clean.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/MacClean-$VERSION.dmg"

# Staging folder = what the user sees when the image is opened: the app next to an
# "Applications" shortcut, so installing is a single drag.
STAGE="build/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Mac Clean" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
