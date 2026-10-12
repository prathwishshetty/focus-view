#!/usr/bin/env bash
# Builds Focus with SwiftPM and wraps it in a runnable, ad-hoc signed Focus.app.
#
#   scripts/bundle.sh            # release build → build/Focus.app
#   scripts/bundle.sh debug      # debug build
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Focus.app"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product Focus
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Focus" "$APP/Contents/MacOS/Focus"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP"
