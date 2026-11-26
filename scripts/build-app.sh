#!/bin/sh
# Builds "build/Flamingo.app" with SwiftPM and signs it ad-hoc.
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

APP="build/Flamingo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Flamingo" "$APP/Contents/MacOS/Flamingo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Version comes from Sources/FlamingoCore/AppVersion.swift (single source).
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/FlamingoCore/AppVersion.swift)"
BUILD="$(sed -n 's/.*static let build = "\(.*\)".*/\1/p' Sources/FlamingoCore/AppVersion.swift)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# Asset catalog (AppIcon + AccentColor, the brand pink used by system buttons).
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --accent-color AccentColor \
    --output-partial-info-plist "$(mktemp -d)/assets.plist" >/dev/null
else
  echo "warning: actool not found (install Xcode); AccentColor will fall back to the system accent" >&2
fi

# .icns from the asset set (also covers builds without actool)
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "$ICONSET_SRC"/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --timestamp=none "$APP"
echo "Built $ROOT/$APP"
