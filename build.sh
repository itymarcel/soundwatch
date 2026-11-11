#!/bin/bash
# Builds soundwatch.app into ./build (ad-hoc signed)
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/AudioWatch"   # the Swift target keeps its old name
APP="build/soundwatch.app"
rm -rf "$APP" build/AudioWatch.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/soundwatch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
echo "Built $APP  -  run with: open $APP"
