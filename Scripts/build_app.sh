#!/usr/bin/env bash
# Build Mac Clean with SwiftPM and assemble a signed .app bundle (no Xcode needed).
# Adapted from App Clean's Scripts/build_app.sh.
# Usage: Scripts/build_app.sh [release|debug] [universal]
#   universal  build for both Apple Silicon and Intel (needed for an app that runs on any Mac)
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Mac Clean.app"

ARCH_FLAGS=()
if [[ "${2:-}" == "universal" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

# ${ARCH_FLAGS[@]+...}: expand to nothing when empty (bash 3.2 on macOS fails on an empty array under set -u).
swift build -c "$CONFIG" --product MacClean ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" --product MacClean ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/MacClean"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacClean"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/en.lproj Resources/vi.lproj "$APP/Contents/Resources/"

# Ad-hoc signature: enough to run on the machine that built it.
codesign --force --sign - "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/MacClean"))"
