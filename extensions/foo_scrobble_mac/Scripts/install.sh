#!/bin/bash
#
# install.sh - Install foo_scrobble_mac to foobar2000
#
# Usage:
#   ./Scripts/install.sh [OPTIONS]
#
# Options:
#   --config CONFIG  Use specified build configuration (Debug/Release, default: Release)
#   --help           Show this help message

set -e

# Configuration
PROJECT_NAME="foo_scrobble"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIG="Release"
# foobar2000 v2 for Mac uses this path structure:
# ~/Library/foobar2000-v2/user-components/<component_name>/<component_name>.component
FOOBAR_COMPONENTS="$HOME/Library/foobar2000-v2/user-components"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
    head -13 "$0" | tail -9
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            BUILD_CONFIG="$2"
            shift 2
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

COMPONENT_PATH="build/$BUILD_CONFIG/$PROJECT_NAME.component"
# foobar2000 v2 expects: user-components/<name>/<name>.component
COMPONENT_FOLDER="$FOOBAR_COMPONENTS/$PROJECT_NAME"
DEST_PATH="$COMPONENT_FOLDER/$PROJECT_NAME.component"

# Check if component exists
if [ ! -d "$COMPONENT_PATH" ]; then
    print_error "Component not found at: $COMPONENT_PATH"
    print_error "Run './Scripts/build.sh' first"
    exit 1
fi

# Create component folder if it doesn't exist
if [ ! -d "$COMPONENT_FOLDER" ]; then
    print_status "Creating component directory..."
    mkdir -p "$COMPONENT_FOLDER"
fi

# Remove existing installation
if [ -d "$DEST_PATH" ]; then
    print_status "Removing existing installation..."
    rm -rf "$DEST_PATH"
fi

# Copy component
print_status "Installing component..."
cp -R "$COMPONENT_PATH" "$DEST_PATH"

# Verify installation
if [ -d "$DEST_PATH" ]; then
    print_success "Component installed successfully!"
    echo "    Location: $DEST_PATH"
    echo ""
    print_warning "Restart foobar2000 to load the component"
else
    print_error "Installation failed!"
    exit 1
fi
