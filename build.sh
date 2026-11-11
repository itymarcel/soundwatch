#!/bin/bash
# Builds soundwatch.app into ./build (ad-hoc signed)
#   ./build.sh               this Mac's architecture (fast)
#   ./build.sh --universal   Apple Silicon + Intel in one app (for releases)
set -euo pipefail
cd "$(dirname "$0")"
APP="build/soundwatch.app"
if [ "${1:-}" = "--universal" ]; then
    BINS=()
    for ARCH in arm64 x86_64; do
        swift build -c release --triple "$ARCH-apple-macosx14.2"
        BINS+=("$(swift build -c release --triple "$ARCH-apple-macosx14.2" --show-bin-path)/AudioWatch")
    done
    BIN="build/AudioWatch-universal"
    mkdir -p build
    lipo -create "${BINS[@]}" -output "$BIN"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/AudioWatch"   # the Swift target keeps its old name
fi
rm -rf "$APP" build/AudioWatch.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/soundwatch"
rm -f build/AudioWatch-universal
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/soundwatch"))  -  run with: open $APP"
