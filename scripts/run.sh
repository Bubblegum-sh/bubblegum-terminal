#!/bin/sh
# Builds a debug Bubblegum.app and launches it. Use this instead of Run in Xcode:
# Xcode runs the bare SwiftPM executable, which has no Info.plist or asset catalog,
# so macOS falls back to system blue for menus and controls and notifications are off.
set -eu
cd "$(dirname "$0")/.."
pkill -x Bubblegum 2>/dev/null || true
scripts/build-app.sh debug
open build/Bubblegum.app
