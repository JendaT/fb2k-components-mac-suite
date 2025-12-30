#!/bin/zsh
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

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Component name mapping (all use jl_ prefix)
typeset -A COMPONENT_MAP=(
    ["simplaylist"]="foo_jl_simplaylist_mac"
    ["jl_simplaylist"]="foo_jl_simplaylist_mac"
    ["plorg"]="foo_jl_plorg_mac"
    ["jl_plorg"]="foo_jl_plorg_mac"
    ["waveform"]="foo_jl_wave_seekbar_mac"
    ["wave_seekbar"]="foo_jl_wave_seekbar_mac"
    ["jl_wave_seekbar"]="foo_jl_wave_seekbar_mac"
    ["scrobble"]="foo_jl_scrobble_mac"
    ["jl_scrobble"]="foo_jl_scrobble_mac"
    ["albumart"]="foo_jl_album_art_mac"
    ["album_art"]="foo_jl_album_art_mac"
    ["jl_album_art"]="foo_jl_album_art_mac"
    ["queue_manager"]="foo_jl_queue_manager_mac"
    ["queuemanager"]="foo_jl_queue_manager_mac"
    ["queue"]="foo_jl_queue_manager_mac"
    ["jl_queue_manager"]="foo_jl_queue_manager_mac"
)

# Version constant mapping in shared/version.h
typeset -A VERSION_MAP=(
    ["simplaylist"]="SIMPLAYLIST_VERSION"
    ["jl_simplaylist"]="SIMPLAYLIST_VERSION"
    ["plorg"]="PLORG_VERSION"
    ["jl_plorg"]="PLORG_VERSION"
    ["waveform"]="WAVEFORM_VERSION"
    ["wave_seekbar"]="WAVEFORM_VERSION"
    ["jl_wave_seekbar"]="WAVEFORM_VERSION"
    ["scrobble"]="SCROBBLE_VERSION"
    ["jl_scrobble"]="SCROBBLE_VERSION"
    ["albumart"]="ALBUMART_VERSION"
    ["album_art"]="ALBUMART_VERSION"
    ["jl_album_art"]="ALBUMART_VERSION"
    ["queue_manager"]="QUEUE_MANAGER_VERSION"
    ["queuemanager"]="QUEUE_MANAGER_VERSION"
    ["queue"]="QUEUE_MANAGER_VERSION"
    ["jl_queue_manager"]="QUEUE_MANAGER_VERSION"
)

# Display names for release titles
typeset -A DISPLAY_NAME_MAP=(
    ["simplaylist"]="SimPlaylist"
    ["jl_simplaylist"]="SimPlaylist"
    ["plorg"]="Playlist Organizer"
    ["jl_plorg"]="Playlist Organizer"
    ["waveform"]="Waveform Seekbar"
    ["wave_seekbar"]="Waveform Seekbar"
    ["jl_wave_seekbar"]="Waveform Seekbar"
    ["scrobble"]="Last.fm Scrobbler"
    ["jl_scrobble"]="Last.fm Scrobbler"
    ["albumart"]="Album Art"
    ["album_art"]="Album Art"
    ["jl_album_art"]="Album Art"
    ["queue_manager"]="Queue Manager"
    ["queuemanager"]="Queue Manager"
    ["queue"]="Queue Manager"
    ["jl_queue_manager"]="Queue Manager"
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
    echo "  albumart      - Album Art (extended album art display)"
    echo "  queue_manager - Queue Manager (visual playback queue)"
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

    local version=$(grep "#define ${version_const} \"" "$PROJECT_ROOT/shared/version.h" | sed 's/.*"\([^"]*\)".*/\1/')

    if [ -z "$version" ]; then
        echo "Error: Could not find version for $component in shared/version.h" >&2
        exit 1
    fi

    echo "$version"
}

# Update version in README.md after release
update_readme_version() {
    local display_name="$1"
    local version="$2"
    local readme="$PROJECT_ROOT/README.md"

    # Escape special characters for sed
    local escaped_name=$(echo "$display_name" | sed 's/\./\\./g')

    # Update version in table row
    # Pattern: | [DisplayName](#...) | Description | VERSION |
    sed -i '' "s/\(| \[${escaped_name}\][^|]*|[^|]*| \)[0-9]*\.[0-9]*\.[0-9]*/\1${version}/" "$readme"

    # Check if there were changes
    if git -C "$PROJECT_ROOT" diff --quiet README.md 2>/dev/null; then
        echo "README.md already up to date"
    else
        echo "Updating README.md with $display_name v$version..."
        git -C "$PROJECT_ROOT" add README.md
        git -C "$PROJECT_ROOT" commit -m "Update $display_name version to $version in README"
        git -C "$PROJECT_ROOT" push origin main
        echo "README.md updated and pushed"
    fi
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
COMPONENT_FILE="foo_jl_${COMPONENT}.fb2k-component"

# Handle special naming conventions (normalize to canonical tag names)
if [ "$COMPONENT" = "simplaylist" ] || [ "$COMPONENT" = "jl_simplaylist" ]; then
    COMPONENT_FILE="foo_jl_simplaylist.fb2k-component"
    TAG_NAME="simplaylist-v${VERSION}"
fi

if [ "$COMPONENT" = "plorg" ] || [ "$COMPONENT" = "jl_plorg" ]; then
    COMPONENT_FILE="foo_jl_plorg.fb2k-component"
    TAG_NAME="plorg-v${VERSION}"
fi

if [ "$COMPONENT" = "waveform" ] || [ "$COMPONENT" = "wave_seekbar" ] || [ "$COMPONENT" = "jl_wave_seekbar" ]; then
    COMPONENT_FILE="foo_jl_wave_seekbar.fb2k-component"
    TAG_NAME="waveform-v${VERSION}"
fi

if [ "$COMPONENT" = "scrobble" ] || [ "$COMPONENT" = "jl_scrobble" ]; then
    COMPONENT_FILE="foo_jl_scrobble.fb2k-component"
    TAG_NAME="scrobble-v${VERSION}"
fi

if [ "$COMPONENT" = "albumart" ] || [ "$COMPONENT" = "album_art" ] || [ "$COMPONENT" = "jl_album_art" ]; then
    COMPONENT_FILE="foo_jl_album_art.fb2k-component"
    TAG_NAME="albumart-v${VERSION}"
fi

if [ "$COMPONENT" = "queue_manager" ] || [ "$COMPONENT" = "queuemanager" ] || [ "$COMPONENT" = "queue" ] || [ "$COMPONENT" = "jl_queue_manager" ]; then
    COMPONENT_FILE="foo_jl_queue_manager.fb2k-component"
    TAG_NAME="queuemanager-v${VERSION}"
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

# Extract changelog for this version from extension's CHANGELOG.md
CHANGELOG_FILE="$EXT_DIR/CHANGELOG.md"
CHANGELOG_CONTENT=""

if [ -f "$CHANGELOG_FILE" ]; then
    # Extract section for current version (from ## [x.x.x] to next ## [ or end)
    CHANGELOG_CONTENT=$(awk -v ver="$VERSION" '
        BEGIN { found=0; printing=0 }
        /^## \[/ {
            if (printing) exit
            if (index($0, "[" ver "]") > 0) { found=1; printing=1; next }
        }
        printing { print }
    ' "$CHANGELOG_FILE")
fi

RELEASE_TITLE="$DISPLAY_NAME v$VERSION"

# Build release notes with changelog content
if [ -n "$CHANGELOG_CONTENT" ]; then
    RELEASE_NOTES="## $DISPLAY_NAME v$VERSION

### What's New

$CHANGELOG_CONTENT

---

### Installation
1. Download \`$COMPONENT_FILE\` below
2. Double-click to install, or manually copy to:
   \`~/Library/foobar2000-v2/user-components/\`
3. Restart foobar2000

### Requirements
- foobar2000 v2.x for macOS
- macOS 11.0 or later"
else
    # Fallback if no changelog found
    RELEASE_NOTES="## $DISPLAY_NAME v$VERSION

### Installation
1. Download \`$COMPONENT_FILE\` below
2. Double-click to install, or manually copy to:
   \`~/Library/foobar2000-v2/user-components/\`
3. Restart foobar2000

### Requirements
- foobar2000 v2.x for macOS
- macOS 11.0 or later"
fi

gh release create "$TAG_NAME" \
    --title "$RELEASE_TITLE" \
    --notes "$RELEASE_NOTES" \
    $DRAFT \
    "$PROJECT_ROOT/$COMPONENT_FILE"

# Clean up package file
rm -f "$PROJECT_ROOT/$COMPONENT_FILE"

# Update README.md with new version (skip for draft releases)
if [ -z "$DRAFT" ]; then
    echo ""
    update_readme_version "$DISPLAY_NAME" "$VERSION"
fi

echo ""
echo "=== Release complete ==="
echo ""
echo "Release URL: https://github.com/JendaT/fb2k-components-mac-suite/releases/tag/$TAG_NAME"
echo ""
echo "Latest download link for forums:"
echo "  https://github.com/JendaT/fb2k-components-mac-suite/releases/download/$TAG_NAME/$COMPONENT_FILE"
