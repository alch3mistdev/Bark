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

echo "▸ Generating icon…"
[ -f Resources/Bark.icns ] || swift scripts/make-icon.swift

echo "▸ Assembling ${APP} ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bark"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Bark.icns "$APP/Contents/Resources/Bark.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Copy SwiftPM resource bundles (tokenizers, crypto) next to the binary.
# No-op for the lean build (no dependency bundles).
for b in ".build/$CONFIG"/*.bundle; do
    [ -e "$b" ] || continue
    cp -R "$b" "$APP/Contents/Resources/"
    echo "  bundled $(basename "$b")"
done

# MLX build: SwiftPM does NOT compile mlx-swift's Metal kernels into a metallib
# (Xcode would), so the app crashes at runtime hunting for default.metallib. We
# compile it ourselves and place it in the bundle MLX looks for (device.cpp).
MLX_SRC=".build/checkouts/mlx-swift/Source/Cmlx"
if grep -q '"MLXCleanup"' Package.swift 2>/dev/null && [ -d "$MLX_SRC/mlx-generated/metal" ]; then
    echo "▸ Compiling MLX default.metallib (SwiftPM doesn't)…"
    MTL_RES="$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources"
    mkdir -p "$MTL_RES"
    xcrun -sdk macosx metal -Wno-everything -fno-fast-math \
        -I "$MLX_SRC/mlx-generated/metal" \
        -I "$MLX_SRC/mlx/mlx/backend/metal/kernels" \
        -I "$MLX_SRC/mlx" \
        "$MLX_SRC"/mlx-generated/metal/*.metal \
        -o "$MTL_RES/default.metallib"
    cp "$MTL_RES/default.metallib" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
    echo "  metallib: $(stat -f%z "$MTL_RES/default.metallib") bytes"
fi

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
