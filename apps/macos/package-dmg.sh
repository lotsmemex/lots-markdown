#!/bin/sh
# Builds the app and packs it into build/LotsMarkdown-<version>.dmg (app + Applications link).
# The app is ad-hoc signed and not notarized: on first launch macOS asks the user to
# confirm in System Settings → Privacy & Security. Developer ID signing comes later.
# Usage: ./package-dmg.sh
set -eu
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
STAGE=build/dmg
DMG="build/LotsMarkdown-$VERSION.dmg"
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
cp -R "build/Lots Markdown.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Lots Markdown $VERSION" -srcfolder "$STAGE" -fs HFS+ -format ULFO "$DMG"
rm -rf "$STAGE"
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
