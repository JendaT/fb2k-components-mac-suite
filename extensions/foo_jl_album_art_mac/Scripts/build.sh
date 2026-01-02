#!/bin/bash
#
# build.sh - Build foo_jl_album_art component
#
# Usage:
#   ./Scripts/build.sh [OPTIONS]
#
# Options:
#   --debug       Build Debug configuration (default: Release)
#   --release     Build Release configuration
#   --clean       Clean before building
#   --regenerate  Regenerate Xcode project before building
#   --install     Install to foobar2000 after building
#   --help        Show this help message

set -e

# Component configuration
PROJECT_NAME="foo_jl_album_art"

# Load shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/../../../shared/scripts/lib.sh"

show_help() {
    head -16 "$0" | tail -12
    exit 0
}

# Parse arguments
if ! parse_build_args "$@"; then
    show_help
fi

# Build options
BUILD_OPTS=""
[ "$CLEAN_FIRST" = true ] && BUILD_OPTS="$BUILD_OPTS --clean"
[ "$REGENERATE" = true ] && BUILD_OPTS="$BUILD_OPTS --regenerate"

# Run build
if do_build $BUILD_OPTS; then
    # Install if requested
    if [ "$INSTALL_AFTER" = true ]; then
        do_install
    fi
else
    exit 1
fi
