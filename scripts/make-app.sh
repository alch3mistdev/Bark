#!/usr/bin/env bash
# Build Bark.app from the SwiftPM executable: assemble the bundle, embed
# Info.plist + entitlements, and code-sign with the hardened runtime.
#
# Usage:
#   scripts/make-app.sh                  # ad-hoc sign (local dev)
#   scripts/make-app.sh "Developer ID Application: You (TEAMID)"   # real signing
#
# Notarization (manual, after real signing):
#   xcrun notarytool submit dist/Bark.zip --apple-id you@example.com --team-id TEAMID --wait
#   xcrun stapler staple dist/Bark.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SIGN_ID="${1:--}"                       # default: ad-hoc "-"
APP="dist/Bark.app"
CONFIG="release"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" --product Bark

BIN=".build/$CONFIG/Bark"
[ -f "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bark"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ Signing with: $SIGN_ID (hardened runtime)…"
codesign --force --options runtime \
    --entitlements Resources/Bark.entitlements \
    --sign "$SIGN_ID" \
    --timestamp=none \
    "$APP"

codesign --verify --verbose "$APP" || true
echo "✓ Built $ROOT/$APP"
echo "  Launch:  open \"$APP\""
echo "  Note: macOS will prompt for Microphone, Accessibility, and Input Monitoring on first use."
