#!/bin/bash
#
# clean.sh - Clean foo_simplaylist_mac build artifacts
#
# Usage:
#   ./Scripts/clean.sh [OPTIONS]
#
# Options:
#   --all      Also remove generated Xcode project
#   --help     Show this help message

set -e

# Configuration
PROJECT_NAME="foo_simplaylist"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEAN_ALL=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}==>${NC} $1"
}

print_success() {
    echo -e "${GREEN}==>${NC} $1"
}

show_help() {
    head -13 "$0" | tail -9
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            CLEAN_ALL=true
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

cd "$PROJECT_DIR"

print_status "Cleaning build artifacts..."

# Remove build directory
if [ -d "build" ]; then
    rm -rf build
    echo "    Removed: build/"
fi

# Remove derived data (if using Xcode GUI)
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$DERIVED_DATA" ]; then
    for dir in "$DERIVED_DATA"/${PROJECT_NAME}*; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            echo "    Removed: $(basename "$dir")"
        fi
    done
fi

# Remove Xcode project if --all specified
if [ "$CLEAN_ALL" = true ]; then
    if [ -d "$PROJECT_NAME.xcodeproj" ]; then
        rm -rf "$PROJECT_NAME.xcodeproj"
        echo "    Removed: $PROJECT_NAME.xcodeproj/"
    fi
fi

print_success "Clean complete!"
