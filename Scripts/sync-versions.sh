#!/bin/zsh
# Syncs version numbers from version.h to README.md
# Usage: ./Scripts/sync-versions.sh
#
# This is a one-time fix script. For ongoing sync, use release_component.sh
# which auto-updates README.md after each release.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$PROJECT_ROOT/shared/version.h"
README_FILE="$PROJECT_ROOT/README.md"

# Component mappings: component_name -> version_constant -> display_name
typeset -A VERSION_MAP
VERSION_MAP=(
    [simplaylist]="SIMPLAYLIST_VERSION"
    [plorg]="PLORG_VERSION"
    [waveform]="WAVEFORM_VERSION"
    [albumart]="ALBUMART_VERSION"
    [queue_manager]="QUEUE_MANAGER_VERSION"
    [scrobble]="SCROBBLE_VERSION"
)

typeset -A DISPLAY_MAP
DISPLAY_MAP=(
    [simplaylist]="SimPlaylist"
    [plorg]="Playlist Organizer"
    [waveform]="Waveform Seekbar"
    [albumart]="Album Art"
    [queue_manager]="Queue Manager"
    [scrobble]="Last.fm Scrobbler"
)

echo "=== Syncing versions from version.h to README.md ==="
echo ""

# Read version from version.h
get_version() {
    local const=$1
    grep "#define ${const} \"" "$VERSION_FILE" | sed 's/.*"\([^"]*\)".*/\1/'
}

# Update version in README.md
update_readme() {
    local component=$1
    local version=$2
    local display_name="${DISPLAY_MAP[$component]}"

    if [ -z "$display_name" ]; then
        echo "Error: Unknown component $component"
        return 1
    fi

    # Escape special characters for sed
    local escaped_name=$(echo "$display_name" | sed 's/\./\\./g')

    # Update version in table row
    # Pattern: | [DisplayName](#...) | Description | VERSION |
    sed -i '' "s/\(| \[${escaped_name}\][^|]*|[^|]*| \)[0-9]*\.[0-9]*\.[0-9]*/\1${version}/" "$README_FILE"

    echo "  $display_name: $version"
}

echo "Versions from $VERSION_FILE:"
echo ""

for component version_const in "${(@kv)VERSION_MAP}"; do
    version=$(get_version "$version_const")
    if [ -n "$version" ]; then
        update_readme "$component" "$version"
    else
        echo "  Warning: Could not find $version_const in version.h"
    fi
done

echo ""
echo "=== Done ==="
echo ""
echo "Changes made to README.md. Review with:"
echo "  git diff README.md"
