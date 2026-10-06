#!/usr/bin/env bash
# Builds build/AINotch.app (and build/AINotch.zip) from the Swift package.
#   CONFIG=debug scripts/build-app.sh      # debug build
#   UNIVERSAL=1 scripts/build-app.sh       # arm64 + x86_64
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
  ARCH_FLAGS=(--arch "$(uname -m)")
fi

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product AINotch
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product ainotch-hook
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

APP=build/AINotch.app
rm -rf "$APP" build/AINotch.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AINotch" "$BIN/ainotch-hook" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"

# Ad-hoc signature by default: enough to run locally on Apple Silicon.
codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP/Contents/MacOS/ainotch-hook"
codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP"
ditto -c -k --keepParent "$APP" build/AINotch.zip
echo "Built $APP ($VERSION)"
