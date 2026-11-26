#!/bin/sh
# Builds a release Flamingo.app and packages it as a drag-to-Applications disk image.
# Output: build/Flamingo-<version>.dmg (+ build/Flamingo.dmg, the stable name the README links to)
# and a .sha256 next to each.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

scripts/build-app.sh release

VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/FlamingoCore/AppVersion.swift)"
APP="build/Flamingo.app"
DMG="build/Flamingo-$VERSION.dmg"
STAGE="$(mktemp -d)/Flamingo"
mkdir -p "$STAGE"

# Contents: the app and a shortcut to /Applications to drag it onto.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Volume icon = the app icon, so the mounted disk shows the flamingo "F" too.
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

rm -f "$DMG" build/Flamingo.dmg
RW="$(mktemp -d)/rw.dmg"
hdiutil create -quiet -volname "Flamingo $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
# Mark the volume as having a custom icon.
MOUNT="$(hdiutil attach -nobrowse -noautoopen "$RW" | sed -n 's|.*\(/Volumes/.*\)|\1|p' | tail -1)"
SetFile -a C "$MOUNT" 2>/dev/null || xcrun SetFile -a C "$MOUNT" 2>/dev/null || true
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"

cp "$DMG" build/Flamingo.dmg
(cd build && shasum -a 256 "Flamingo-$VERSION.dmg" > "Flamingo-$VERSION.dmg.sha256" && shasum -a 256 Flamingo.dmg > Flamingo.dmg.sha256)
echo "Built $ROOT/$DMG"
