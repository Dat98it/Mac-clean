#!/usr/bin/env bash
# Build Mac Clean with SwiftPM and assemble a signed .app bundle (no Xcode needed).
# Adapted from App Clean's Scripts/build_app.sh.
# Usage: Scripts/build_app.sh [release|debug]
# Apple Silicon only (arm64), macOS 15 or later.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Mac Clean.app"

swift build -c "$CONFIG" --product MacClean --arch arm64
BIN="$(swift build -c "$CONFIG" --product MacClean --arch arm64 --show-bin-path)/MacClean"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacClean"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The menu bar glyph (template image, 1x and 2x). The *-source.png artwork stays out of the app.
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
cp -R Resources/en.lproj Resources/vi.lproj "$APP/Contents/Resources/"

# Ad-hoc signature: enough to run on the machine that built it.
codesign --force --sign - "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/MacClean"))"
