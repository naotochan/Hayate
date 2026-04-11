#!/bin/bash
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/build-release.sh <version>"
    echo "Example: ./scripts/build-release.sh 0.1.0"
    exit 1
fi

SCHEME="Hayate"
BUILD_DIR="build/release"
APP_NAME="Hayate.app"
ZIP_NAME="Hayate-${VERSION}-mac.zip"

echo "==> Building Hayate v${VERSION} (Release)..."
rm -rf "$BUILD_DIR"

xcodebuild \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -archivePath "$BUILD_DIR/Hayate.xcarchive" \
    archive \
    CODE_SIGN_IDENTITY="-" \
    MARKETING_VERSION="$VERSION" \
    2>&1 | tail -5

# Extract .app from archive
ARCHIVE_APP="$BUILD_DIR/Hayate.xcarchive/Products/Applications/$APP_NAME"
if [ ! -d "$ARCHIVE_APP" ]; then
    echo "ERROR: $APP_NAME not found in archive"
    exit 1
fi

echo "==> Packaging..."
DIST_DIR="$BUILD_DIR/dist"
mkdir -p "$DIST_DIR"
cp -R "$ARCHIVE_APP" "$DIST_DIR/"

# Create zip
cd "$DIST_DIR"
zip -r -y "../../$ZIP_NAME" "$APP_NAME" > /dev/null
cd - > /dev/null

echo "==> Created: $ZIP_NAME"
echo ""
echo "To create a GitHub release:"
echo "  gh release create v${VERSION} ${ZIP_NAME} --title \"Hayate v${VERSION}\" --notes \"Release v${VERSION}\""
