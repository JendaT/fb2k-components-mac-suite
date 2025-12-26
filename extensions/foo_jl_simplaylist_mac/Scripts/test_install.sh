#!/bin/bash
#
# test_install.sh - Build and install component for testing
#
# This script performs a clean build and installs the component
# to the local foobar2000 user-components folder for testing.
#
# Usage:
#   ./Scripts/test_install.sh [OPTIONS]
#
# Options:
#   --debug        Build Debug configuration (default: Release)
#   --no-clean     Skip cleaning before build
#   --regenerate   Force regenerate Xcode project
#   --help         Show this help message

set -e

# Configuration
PROJECT_NAME="foo_simplaylist"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIG="Release"
CLEAN_FIRST=true
REGENERATE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

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
    head -17 "$0" | tail -13
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            BUILD_CONFIG="Debug"
            shift
            ;;
        --no-clean)
            CLEAN_FIRST=false
            shift
            ;;
        --regenerate)
            REGENERATE=true
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

print_header "Test Install: $PROJECT_NAME"

# Step 1: Clean (optional)
if [ "$CLEAN_FIRST" = true ]; then
    print_status "Step 1: Cleaning previous build..."
    ./Scripts/clean.sh
else
    print_status "Step 1: Skipping clean (--no-clean)"
fi

# Step 2: Generate project (if needed or forced)
if [ "$REGENERATE" = true ] || [ ! -d "$PROJECT_NAME.xcodeproj" ]; then
    print_status "Step 2: Generating Xcode project..."
    ruby Scripts/generate_xcode_project.rb
else
    print_status "Step 2: Using existing Xcode project"
fi

# Step 3: Build
print_status "Step 3: Building ($BUILD_CONFIG)..."
xcodebuild -project "$PROJECT_NAME.xcodeproj" \
           -target "$PROJECT_NAME" \
           -configuration "$BUILD_CONFIG" \
           build 2>&1 | while read line; do
    # Filter output for readability
    if echo "$line" | grep -qE "^(CompileC|Ld |Create|Touch|\*\* BUILD)"; then
        if echo "$line" | grep -q "CompileC"; then
            FILE=$(echo "$line" | grep -oE "[^ ]+\.(cpp|mm|m)$" | head -1)
            if [ -n "$FILE" ]; then
                echo "    Compiling: $(basename "$FILE")"
            fi
        elif echo "$line" | grep -q "^Ld "; then
            echo "    Linking..."
        elif echo "$line" | grep -q "CREATE"; then
            echo "    Creating universal binary..."
        elif echo "$line" | grep -q "BUILD SUCCEEDED"; then
            echo ""
            print_success "Build succeeded!"
        elif echo "$line" | grep -q "BUILD FAILED"; then
            echo ""
            print_error "Build failed!"
        fi
    fi
done

# Check build result
COMPONENT_PATH="build/$BUILD_CONFIG/$PROJECT_NAME.component"
if [ ! -d "$COMPONENT_PATH" ]; then
    print_error "Build failed - component not found"
    exit 1
fi

# Step 4: Install
print_status "Step 4: Installing to foobar2000..."
./Scripts/install.sh --config "$BUILD_CONFIG"

# Summary
print_header "Installation Complete"
echo "Component: $PROJECT_NAME.component"
echo "Configuration: $BUILD_CONFIG"
echo ""
print_warning "Restart foobar2000 to test the component"
echo ""
echo "To add the SimPlaylist view:"
echo "  1. Right-click on foobar2000 window"
echo "  2. Select 'Add UI Element'"
echo "  3. Choose 'SimPlaylist'"
echo ""
