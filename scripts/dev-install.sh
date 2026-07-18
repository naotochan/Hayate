#!/bin/bash
# Fast local iteration: build a Release .app and drop it into /Applications,
# quitting any running instance first. Not a release — no zip, sign, or appcast.
# Usage: ./scripts/dev-install.sh [--run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

SCHEME="Hayate"
DERIVED="build/install-dd"
APP="$DERIVED/Build/Products/Release/$SCHEME.app"
DEST="/Applications/$SCHEME.app"

echo "==> Quitting running instance (if any)…"
osascript -e "quit app \"$SCHEME\"" 2>/dev/null || true
sleep 1

echo "==> Building Release…"
xcodebuild -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" build 2>&1 | tail -3

[ -d "$APP" ] || { echo "ERROR: $APP not found"; exit 1; }

echo "==> Installing to ${DEST}…"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$DEST"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist")
echo "==> Installed Hayate $VERSION (build $BUILD)"

if [ "${1:-}" = "--run" ]; then
    open "$DEST"
    echo "==> Launched."
fi
