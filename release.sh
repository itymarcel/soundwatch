#!/bin/bash
# Builds a universal soundwatch.app (signed like build.sh) and zips it for a GitHub release.
# The version comes from CFBundleShortVersionString in Resources/Info.plist (bump it there first).
#   ./release.sh   →  build/soundwatch-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
./build.sh --universal
ZIP="build/soundwatch-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/soundwatch.app "$ZIP"   # ditto keeps the signature intact
codesign --verify --deep --strict build/soundwatch.app
echo
echo "Release file: $ZIP ($(du -h "$ZIP" | cut -f1))"
codesign -d -r- build/soundwatch.app 2>&1 | grep -q 'designated => cdhash' \
    && echo "Warning: ad-hoc signed - users will be asked for the audio permission again after updating (Resources/make_signing_cert.sh)"
echo "Tag: v$VERSION  -  upload the zip on GitHub → Releases → Draft a new release"
