#!/usr/bin/env bash
# Build Bark.app then package it into dist/Bark.dmg with a drag-to-Applications
# layout. Uses only built-in tools (hdiutil). Ad-hoc signed by default.
#
# Usage: scripts/make-dmg.sh ["Developer ID Application: ..."]
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_ID="${1:--}"
VOL="Bark"
DMG="dist/Bark.dmg"
STAGE="build/dmg"

# 1) Build the .app
scripts/make-app.sh "$SIGN_ID"

# 2) Stage a folder with the app + an Applications symlink
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R dist/Bark.app "$STAGE/Bark.app"
ln -s /Applications "$STAGE/Applications"

# 3) Build a compressed DMG from the staged folder
echo "▸ Building ${DMG} ..."
hdiutil create \
    -volname "$VOL" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

rm -rf "$STAGE"
SIZE=$(du -h "$DMG" | cut -f1)
echo "✓ $DMG ($SIZE)"
echo
echo "Install: open \"$DMG\" → drag Bark to Applications."
echo "First launch (ad-hoc/unsigned): right-click Bark.app → Open (bypasses Gatekeeper once),"
echo "or run: xattr -dr com.apple.quarantine /Applications/Bark.app"
