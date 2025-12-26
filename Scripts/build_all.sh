#!/bin/bash
#
# Build all foobar2000 macOS extensions
#
# Usage: ./build_all.sh [--clean] [--install]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

CLEAN=false
INSTALL=false

for arg in "$@"; do
    case $arg in
        --clean)
            CLEAN=true
            ;;
        --install)
            INSTALL=true
            ;;
    esac
done

EXTENSIONS=(
    "foo_jl_simplaylist_mac"
    "foo_jl_plorg_mac"
    "foo_jl_wave_seekbar_mac"
    "foo_jl_scrobble_mac"
)

echo "Building all foobar2000 macOS extensions..."
echo ""

for ext in "${EXTENSIONS[@]}"; do
    EXT_DIR="$PROJECT_ROOT/extensions/$ext"

    if [ ! -d "$EXT_DIR" ]; then
        echo "Warning: $ext not found, skipping"
        continue
    fi

    echo "=== Building $ext ==="
    cd "$EXT_DIR"

    # Generate Xcode project if needed
    if [ ! -f "*.xcodeproj" ] && [ -f "Scripts/generate_xcode_project.rb" ]; then
        echo "Generating Xcode project..."
        ruby Scripts/generate_xcode_project.rb
    fi

    # Clean if requested
    if [ "$CLEAN" = true ] && [ -f "Scripts/clean.sh" ]; then
        ./Scripts/clean.sh
    fi

    # Build
    if [ -f "Scripts/build.sh" ]; then
        ./Scripts/build.sh
    else
        echo "Warning: No build script found for $ext"
    fi

    # Install if requested
    if [ "$INSTALL" = true ] && [ -f "Scripts/install.sh" ]; then
        ./Scripts/install.sh
    fi

    echo ""
done

echo "Build complete!"
