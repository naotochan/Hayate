#!/bin/bash
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/build-release.sh <version>"
    echo "Example: ./scripts/build-release.sh 0.2.0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="Hayate"
BUILD_DIR="build/release"
APP_NAME="Hayate.app"
ZIP_NAME="Hayate-${VERSION}-mac.zip"
SPARKLE_TOOLS="$SCRIPT_DIR/sparkle-tools"
DOCS_DIR="$PROJECT_DIR/docs"

# Build number must be monotonic across releases so Sparkle's version comparator
# picks up updates. Use git commit count — always increases, reproducible from tree state.
BUILD_NUMBER=$(git rev-list --count HEAD)

echo "==> Building Hayate v${VERSION} (build ${BUILD_NUMBER}, Release)..."
rm -rf "$BUILD_DIR"

xcodebuild \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -archivePath "$BUILD_DIR/Hayate.xcarchive" \
    archive \
    CODE_SIGN_IDENTITY="-" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
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

# Create zip (preserve symlinks)
cd "$DIST_DIR"
zip -r -y "$PROJECT_DIR/$BUILD_DIR/$ZIP_NAME" "$APP_NAME" > /dev/null
cd "$PROJECT_DIR"

echo "==> Created: $BUILD_DIR/$ZIP_NAME"

# EdDSA sign the zip
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-$HOME/.sparkle_eddsa_key}"
if [ -x "$SPARKLE_TOOLS/sign_update" ] && [ -f "$SPARKLE_KEY_FILE" ]; then
    echo "==> Signing with EdDSA..."
    SIGNATURE=$("$SPARKLE_TOOLS/sign_update" "$BUILD_DIR/$ZIP_NAME" -f "$SPARKLE_KEY_FILE" 2>&1)
    echo "    $SIGNATURE"

    # Generate appcast.xml
    echo "==> Generating appcast.xml..."
    mkdir -p "$DOCS_DIR"

    FILE_SIZE=$(stat -f%z "$BUILD_DIR/$ZIP_NAME")
    # Extract edSignature and length from sign_update output
    ED_SIGNATURE=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="//;s/"//')
    PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S %z")
    DOWNLOAD_URL="https://github.com/naotochan/Hayate/releases/download/v${VERSION}/${ZIP_NAME}"

    cat > "$DOCS_DIR/appcast.xml" << APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Hayate Updates</title>
    <link>https://github.com/naotochan/Hayate</link>
    <description>Hayate update feed</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
        url="${DOWNLOAD_URL}"
        length="${FILE_SIZE}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}"
      />
    </item>
  </channel>
</rss>
APPCAST_EOF

    echo "==> Updated: docs/appcast.xml"
else
    echo "WARNING: sparkle-tools or key file not found, skipping signing"
    echo "  Tools: $SPARKLE_TOOLS/sign_update"
    echo "  Key:   $SPARKLE_KEY_FILE"
fi

echo ""
echo "==> Done! Next steps:"
echo "  1. gh release create v${VERSION} ${BUILD_DIR}/${ZIP_NAME} --title \"Hayate v${VERSION}\" --notes \"Release v${VERSION}\""
echo "  2. git add docs/appcast.xml && git commit -m \"release: update appcast for v${VERSION}\""
echo "  3. git push origin main  (updates GitHub Pages)"
