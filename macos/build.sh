#!/bin/bash
# Builds Ravi.app from macos/Sources and the shared card, installs it in Applications and starts it.
#   bash macos/build.sh             build, install, start
#   bash macos/build.sh --no-install  just build (into macos/build/Ravi.app); used by GitHub Actions
set -euo pipefail
cd "$(dirname "$0")"
SHARED="../shared"
INSTALL=1
[ "${1:-}" = "--no-install" ] && INSTALL=0

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift isn't installed yet. Run this, accept the prompt, then run build.sh again:"
  echo "  xcode-select --install"
  exit 1
fi

echo "Building Ravi..."
rm -rf build
APP="build/Ravi.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/shared"

# a universal app: runs natively on Apple silicon and Intel Macs
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos13.0" \
    Sources/Core.swift Sources/App.swift \
    -o "build/Ravi-$arch" \
    -framework AppKit -framework WebKit -framework ServiceManagement -framework Carbon
done
lipo -create build/Ravi-arm64 build/Ravi-x86_64 -output "$APP/Contents/MacOS/Ravi"
rm build/Ravi-arm64 build/Ravi-x86_64

cp Info.plist "$APP/Contents/"
cp -R "$SHARED/card.html" "$SHARED/moves.json" "$SHARED/fonts" "$SHARED/icons" "$APP/Contents/Resources/shared/"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

if [ "$INSTALL" = 0 ]; then
  echo "Built $(pwd)/$APP"
  exit 0
fi

osascript -e 'quit app "Ravi"' >/dev/null 2>&1 || pkill -x Ravi 2>/dev/null || true
sleep 0.8

DEST="/Applications"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
rm -rf "$DEST/Ravi.app"
cp -R "$APP" "$DEST/"
open "$DEST/Ravi.app"

echo ""
echo "Done. Ravi is running: look for the little ravioli in your menu bar."
echo "Installed at $DEST/Ravi.app"
