#!/bin/bash
# Fast local iteration: bump build (and optionally marketing version), build a
# Release .app, and drop it into /Applications. Not a release — no zip, sign,
# or appcast.
# Usage: ./scripts/dev-install.sh [--run] [--bump-patch|--bump-minor|--no-bump]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

SCHEME="Hayate"
PBXPROJ="Hayate.xcodeproj/project.pbxproj"
DERIVED="build/install-dd"
APP="$DERIVED/Build/Products/Release/$SCHEME.app"
DEST="/Applications/$SCHEME.app"

RUN=0
BUMP_BUILD=1
BUMP_MARKETING=""  # patch | minor | ""

for arg in "$@"; do
    case "$arg" in
        --run) RUN=1 ;;
        --bump-patch) BUMP_MARKETING=patch ;;
        --bump-minor) BUMP_MARKETING=minor ;;
        --no-bump) BUMP_BUILD=0; BUMP_MARKETING="" ;;
        -h|--help)
            sed -n '2,7p' "$0" | tr -d '#'
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

# Read current Hayate app versions from the first MARKETING_VERSION /
# CURRENT_PROJECT_VERSION pair in the pbxproj (app target precedes tests).
read_versions() {
    MARKETING=$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ" | sed 's/.*MARKETING_VERSION = \([^;]*\);/\1/')
    BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/')
}

bump_semver() {
    local ver="$1" part="$2"
    local major minor patch
    IFS=. read -r major minor patch <<< "$ver"
    major=${major:-0}; minor=${minor:-0}; patch=${patch:-0}
    case "$part" in
        patch) patch=$((patch + 1)) ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        *) echo "ERROR: unknown semver part: $part" >&2; exit 1 ;;
    esac
    echo "${major}.${minor}.${patch}"
}

# Replace only the first two occurrences (Debug + Release for Hayate.app).
# Test target keeps MARKETING_VERSION = 1.0 / CURRENT_PROJECT_VERSION = 1.
write_versions() {
    local new_marketing="$1" new_build="$2"
    python3 - "$PBXPROJ" "$new_marketing" "$new_build" <<'PY'
import re, sys
path, marketing, build = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()

def replace_n(pattern, repl, n):
    global text
    count = 0
    def _sub(m):
        nonlocal count
        count += 1
        return repl if count <= n else m.group(0)
    text, _ = re.subn(pattern, _sub, text)
    if count < n:
        sys.exit(f"ERROR: expected {n} matches for {pattern!r}, found {count}")

replace_n(r"CURRENT_PROJECT_VERSION = \d+;", f"CURRENT_PROJECT_VERSION = {build};", 2)
replace_n(r"MARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {marketing};", 2)
open(path, "w").write(text)
PY
}

read_versions
OLD_MARKETING="$MARKETING"
OLD_BUILD="$BUILD"

if [ "$BUMP_BUILD" -eq 1 ] || [ -n "$BUMP_MARKETING" ]; then
    NEW_BUILD="$OLD_BUILD"
    NEW_MARKETING="$OLD_MARKETING"
    if [ "$BUMP_BUILD" -eq 1 ]; then
        NEW_BUILD=$((OLD_BUILD + 1))
    fi
    if [ -n "$BUMP_MARKETING" ]; then
        NEW_MARKETING=$(bump_semver "$OLD_MARKETING" "$BUMP_MARKETING")
    fi
    echo "==> Version ${OLD_MARKETING} (${OLD_BUILD}) → ${NEW_MARKETING} (${NEW_BUILD})"
    write_versions "$NEW_MARKETING" "$NEW_BUILD"
else
    echo "==> Version ${OLD_MARKETING} (build ${OLD_BUILD}) — no bump"
fi

echo "==> Quitting running instance (if any)…"
osascript -e "quit app \"$SCHEME\"" 2>/dev/null || true
sleep 1

echo "==> Building Release…"
xcodebuild -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" build 2>&1 | tail -5

[ -d "$APP" ] || { echo "ERROR: $APP not found"; exit 1; }

echo "==> Installing to ${DEST}…"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$DEST"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist")
echo "==> Installed Hayate $VERSION (build $BUILD)"

if [ "$RUN" -eq 1 ]; then
    open "$DEST"
    echo "==> Launched."
fi
