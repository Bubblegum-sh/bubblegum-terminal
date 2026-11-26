#!/bin/sh
# Builds "build/Terminal Flamingo.app" with SwiftPM and signs it ad-hoc.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -eu

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# SwiftUI's macros ship with Xcode, not the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ICONSET_SRC="Resources/Assets.xcassets/AppIcon.appiconset"
if [ ! -f "$ICONSET_SRC/icon_512x512@2x.png" ]; then
  swift scripts/make-icon.swift "$ICONSET_SRC"
fi

swift build -c "$CONFIG" --arch arm64 --arch x86_64 2>/dev/null || swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null || swift build -c "$CONFIG" --show-bin-path)"

APP="build/Terminal Flamingo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TerminalFlamingo" "$APP/Contents/MacOS/TerminalFlamingo"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# .icns from the asset set
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "$ICONSET_SRC"/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --timestamp=none "$APP"
echo "Built $ROOT/$APP"
