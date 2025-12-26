#!/bin/bash
#
# build.sh - Build foo_jl_simplaylist_mac component
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

# Configuration
PROJECT_NAME="foo_jl_simplaylist"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIG="Release"
CLEAN_FIRST=false
REGENERATE=false
INSTALL_AFTER=false
FOOBAR_COMPONENTS="$HOME/Library/foobar2000-v2/user-components"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}==>${NC} $1"
}

print_success() {
    echo -e "${GREEN}==>${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}==>${NC} $1"
}

print_error() {
    echo -e "${RED}==>${NC} $1"
}

show_help() {
    head -20 "$0" | tail -15
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            BUILD_CONFIG="Debug"
            shift
            ;;
        --release)
            BUILD_CONFIG="Release"
            shift
            ;;
        --clean)
            CLEAN_FIRST=true
            shift
            ;;
        --regenerate)
            REGENERATE=true
            shift
            ;;
        --install)
            INSTALL_AFTER=true
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            ;;
    esac
done

cd "$PROJECT_DIR"

print_status "Building $PROJECT_NAME ($BUILD_CONFIG)"

# Regenerate Xcode project if requested or if it doesn't exist
if [ "$REGENERATE" = true ] || [ ! -d "$PROJECT_NAME.xcodeproj" ]; then
    print_status "Generating Xcode project..."
    ruby Scripts/generate_xcode_project.rb
fi

# Clean if requested
if [ "$CLEAN_FIRST" = true ]; then
    print_status "Cleaning build directory..."
    rm -rf build
fi

# Build
print_status "Building with xcodebuild..."
xcodebuild -project "$PROJECT_NAME.xcodeproj" \
           -target "$PROJECT_NAME" \
           -configuration "$BUILD_CONFIG" \
           build \
           | grep -E "^(Build|Compile|Ld|Create|Touch|\*\*)" || true

# Check build result
COMPONENT_PATH="build/$BUILD_CONFIG/$PROJECT_NAME.component"
if [ -d "$COMPONENT_PATH" ]; then
    print_success "Build succeeded!"
    echo "    Output: $COMPONENT_PATH"

    # Show binary info
    BINARY_PATH="$COMPONENT_PATH/Contents/MacOS/$PROJECT_NAME"
    if [ -f "$BINARY_PATH" ]; then
        SIZE=$(du -h "$BINARY_PATH" | cut -f1)
        ARCHS=$(file "$BINARY_PATH" | grep -oE "(x86_64|arm64)" | tr '\n' ' ')
        echo "    Size: $SIZE"
        echo "    Architectures: $ARCHS"
    fi

    # Install if requested
    if [ "$INSTALL_AFTER" = true ]; then
        "$PROJECT_DIR/Scripts/install.sh" --config "$BUILD_CONFIG"
    fi
else
    print_error "Build failed!"
    exit 1
fi
