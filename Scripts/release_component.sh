#!/bin/bash
#
# Release a foobar2000 macOS component
#
# Usage: ./release_component.sh <component_name> [--draft]
#
# Examples:
#   ./release_component.sh simplaylist
#   ./release_component.sh plorg --draft
#
# This script will:
#   1. Read the component's version from shared/version.h
#   2. Build the component (Release configuration)
#   3. Package as .fb2k-component
#   4. Create a git tag (e.g., simplaylist-v1.0.0)
#   5. Create a GitHub release with the component attached
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Component name mapping
declare -A COMPONENT_MAP=(
    ["simplaylist"]="foo_simplaylist_mac"
    ["plorg"]="foo_plorg_mac"
    ["waveform"]="foo_wave_seekbar_mac"
    ["wave_seekbar"]="foo_wave_seekbar_mac"
    ["scrobble"]="foo_scrobble_mac"
)

# Version constant mapping in shared/version.h
declare -A VERSION_MAP=(
    ["simplaylist"]="SIMPLAYLIST_VERSION"
    ["plorg"]="PLORG_VERSION"
    ["waveform"]="WAVEFORM_VERSION"
    ["wave_seekbar"]="WAVEFORM_VERSION"
    ["scrobble"]="SCROBBLE_VERSION"
)

# Display names for release titles
declare -A DISPLAY_NAME_MAP=(
    ["simplaylist"]="SimPlaylist"
    ["plorg"]="Playlist Organizer"
    ["waveform"]="Waveform Seekbar"
    ["wave_seekbar"]="Waveform Seekbar"
    ["scrobble"]="Last.fm Scrobbler"
)

show_help() {
    echo "Release a foobar2000 macOS component"
    echo ""
    echo "Usage: $0 <component_name> [--draft]"
    echo ""
    echo "Components:"
    echo "  simplaylist   - SimPlaylist (flat playlist view)"
    echo "  plorg         - Playlist Organizer"
    echo "  waveform      - Waveform Seekbar"
    echo "  scrobble      - Last.fm Scrobbler"
    echo ""
    echo "Options:"
    echo "  --draft       Create as draft release (not published)"
    echo ""
    echo "Examples:"
    echo "  $0 simplaylist"
    echo "  $0 plorg --draft"
}

get_version() {
    local component="$1"
    local version_const="${VERSION_MAP[$component]}"

    if [ -z "$version_const" ]; then
        echo "Error: Unknown component '$component'" >&2
        exit 1
    fi

    local version=$(grep "#define $version_const" "$PROJECT_ROOT/shared/version.h" | sed 's/.*"\([^"]*\)".*/\1/')

    if [ -z "$version" ]; then
        echo "Error: Could not find version for $component in shared/version.h" >&2
        exit 1
    fi

    echo "$version"
}

# Parse arguments
if [ -z "$1" ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    show_help
    exit 0
fi

COMPONENT="$1"
DRAFT=""

shift
while [ $# -gt 0 ]; do
    case "$1" in
        --draft)
            DRAFT="--draft"
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

# Validate component
EXT_DIR_NAME="${COMPONENT_MAP[$COMPONENT]}"
if [ -z "$EXT_DIR_NAME" ]; then
    echo "Error: Unknown component '$COMPONENT'"
    echo ""
    show_help
    exit 1
fi

EXT_DIR="$PROJECT_ROOT/extensions/$EXT_DIR_NAME"
if [ ! -d "$EXT_DIR" ]; then
    echo "Error: Extension directory not found: $EXT_DIR"
    exit 1
fi

# Get version
VERSION=$(get_version "$COMPONENT")
DISPLAY_NAME="${DISPLAY_NAME_MAP[$COMPONENT]}"
TAG_NAME="${COMPONENT}-v${VERSION}"
COMPONENT_FILE="foo_${COMPONENT}.fb2k-component"

# Handle waveform naming
if [ "$COMPONENT" = "waveform" ] || [ "$COMPONENT" = "wave_seekbar" ]; then
    COMPONENT_FILE="foo_wave_seekbar.fb2k-component"
    TAG_NAME="waveform-v${VERSION}"
fi

echo "=== Releasing $DISPLAY_NAME v$VERSION ==="
echo ""
echo "  Component:  $COMPONENT"
echo "  Version:    $VERSION"
echo "  Tag:        $TAG_NAME"
echo "  Package:    $COMPONENT_FILE"
echo ""

# Check for uncommitted changes
if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ]; then
    echo "Error: You have uncommitted changes. Please commit or stash them first."
    exit 1
fi

# Check if tag already exists
if git -C "$PROJECT_ROOT" rev-parse "$TAG_NAME" >/dev/null 2>&1; then
    echo "Error: Tag '$TAG_NAME' already exists."
    echo "If you want to re-release, delete the tag first:"
    echo "  git tag -d $TAG_NAME"
    echo "  git push origin :refs/tags/$TAG_NAME"
    exit 1
fi

# Build the component
echo "Building $DISPLAY_NAME..."
cd "$EXT_DIR"

# Regenerate Xcode project
if [ -f "Scripts/generate_xcode_project.rb" ]; then
    ruby Scripts/generate_xcode_project.rb
fi

# Build
if [ -f "Scripts/build.sh" ]; then
    ./Scripts/build.sh
else
    # Fallback to direct xcodebuild
    PROJECT_FILE=$(ls -d *.xcodeproj 2>/dev/null | head -1)
    if [ -n "$PROJECT_FILE" ]; then
        xcodebuild -project "$PROJECT_FILE" -configuration Release build
    else
        echo "Error: No build script or Xcode project found"
        exit 1
    fi
fi

# Package
echo ""
echo "Packaging..."
cd "$PROJECT_ROOT"
"$SCRIPT_DIR/package.sh" "${COMPONENT//_/-}"

# Verify package exists
if [ ! -f "$PROJECT_ROOT/$COMPONENT_FILE" ]; then
    # Try alternative naming
    ALT_FILE="foo_${COMPONENT//-/_}.fb2k-component"
    if [ -f "$PROJECT_ROOT/$ALT_FILE" ]; then
        COMPONENT_FILE="$ALT_FILE"
    else
        echo "Error: Package not found: $COMPONENT_FILE"
        exit 1
    fi
fi

echo ""
echo "Package created: $COMPONENT_FILE ($(du -h "$PROJECT_ROOT/$COMPONENT_FILE" | cut -f1))"

# Create tag
echo ""
echo "Creating tag: $TAG_NAME"
git -C "$PROJECT_ROOT" tag -a "$TAG_NAME" -m "$DISPLAY_NAME v$VERSION"
git -C "$PROJECT_ROOT" push origin "$TAG_NAME"

# Create GitHub release
echo ""
echo "Creating GitHub release..."

RELEASE_TITLE="$DISPLAY_NAME v$VERSION"
RELEASE_NOTES="## $DISPLAY_NAME v$VERSION

### Installation
1. Download \`$COMPONENT_FILE\` below
2. Double-click to install, or manually copy to:
   \`~/Library/Application Support/foobar2000/user-components/\`
3. Restart foobar2000

### Requirements
- foobar2000 v2.x for macOS
- macOS 11.0 or later

---
See [CHANGELOG.md](https://github.com/JendaT/fb2k-components-mac-suite/blob/main/CHANGELOG.md) for details."

gh release create "$TAG_NAME" \
    --title "$RELEASE_TITLE" \
    --notes "$RELEASE_NOTES" \
    $DRAFT \
    "$PROJECT_ROOT/$COMPONENT_FILE"

# Clean up package file
rm -f "$PROJECT_ROOT/$COMPONENT_FILE"

echo ""
echo "=== Release complete ==="
echo ""
echo "Release URL: https://github.com/JendaT/fb2k-components-mac-suite/releases/tag/$TAG_NAME"
echo ""
echo "Latest download link for forums:"
echo "  https://github.com/JendaT/fb2k-components-mac-suite/releases/download/$TAG_NAME/$COMPONENT_FILE"
