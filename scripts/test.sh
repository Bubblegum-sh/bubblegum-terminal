#!/bin/sh
# Runs the unit tests. Uses Xcode's toolchain when installed (Swift Testing's macros
# are not found by SwiftPM under the Command Line Tools alone).
set -eu
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  exec swift test "$@"
fi
exec swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
