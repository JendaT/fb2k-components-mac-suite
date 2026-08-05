#!/bin/bash
#
# lib.sh - Shared library for foobar2000 component build scripts
#
# Source this file from extension scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../../../shared/scripts/lib.sh"
#
# Required variables (set before sourcing):
#   PROJECT_NAME - Component name (e.g., "foo_jl_wave_seekbar")
#
# Optional variables:
#   BUILD_CONFIG - Debug or Release (default: Release)
#

# Ensure PROJECT_NAME is set
if [ -z "$PROJECT_NAME" ]; then
    echo "Error: PROJECT_NAME must be set before sourcing lib.sh"
    exit 1
fi

# Paths
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$PROJECT_DIR/../.." && pwd)}"
SHARED_DIR="$REPO_ROOT/shared"
BUILD_CONFIG="${BUILD_CONFIG:-Release}"

# foobar2000 v2 component paths
FOOBAR_COMPONENTS="$HOME/Library/foobar2000-v2/user-components"
COMPONENT_FOLDER="$FOOBAR_COMPONENTS/$PROJECT_NAME"

# Build output paths (local to project, not DerivedData)
BUILD_DIR="$PROJECT_DIR/build"
COMPONENT_PATH="$BUILD_DIR/$BUILD_CONFIG/$PROJECT_NAME.component"
DEST_PATH="$COMPONENT_FOLDER/$PROJECT_NAME.component"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Print functions
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

print_info() {
    echo -e "${CYAN}   ${NC} $1"
}

# Build the component
# Usage: do_build [--clean] [--regenerate]
do_build() {
    local clean_first=false
    local regenerate=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --clean) clean_first=true; shift ;;
            --regenerate) regenerate=true; shift ;;
            *) shift ;;
        esac
    done

    cd "$PROJECT_DIR" || { print_error "Cannot enter project directory: $PROJECT_DIR"; return 1; }

    print_status "Building $PROJECT_NAME ($BUILD_CONFIG)"

    # Regenerate Xcode project if requested or if it doesn't exist
    if [ "$regenerate" = true ] || [ ! -d "$PROJECT_NAME.xcodeproj" ]; then
        print_status "Generating Xcode project..."
        ruby Scripts/generate_xcode_project.rb || { print_error "Project generation failed"; return 1; }
    fi

    # Clean if requested
    if [ "$clean_first" = true ]; then
        print_status "Cleaning build directory..."
        rm -rf "$BUILD_DIR"
    fi

    # Ensure build directory exists
    mkdir -p "$BUILD_DIR" || { print_error "Cannot create build directory: $BUILD_DIR"; return 1; }

    # Build with xcodebuild
    # SYMROOT forces output to local build/ instead of DerivedData
    print_status "Building with xcodebuild..."

    local build_log="$BUILD_DIR/build.log"

    set +e
    xcodebuild -project "$PROJECT_NAME.xcodeproj" \
               -target "$PROJECT_NAME" \
               -configuration "$BUILD_CONFIG" \
               SYMROOT="$BUILD_DIR" \
               build \
               > "$build_log" 2>&1
    local build_exit=$?
    set -e

    # Show filtered build progress
    grep -E "^(Compile|Ld|Create|Touch)|warning:" "$build_log" || true

    # Check xcodebuild exit code first (don't rely on stale output directory)
    if [ $build_exit -ne 0 ]; then
        echo ""
        print_error "========================================="
        print_error "  BUILD FAILED (exit code: $build_exit)"
        print_error "========================================="
        echo ""
        grep -E "(error:|fatal error:|BUILD FAILED)" "$build_log" || true
        echo ""
        print_error "Last 20 lines of build log:"
        tail -20 "$build_log"
        echo ""
        print_error "Full log: $build_log"
        return 1
    fi

    # Verify the output actually exists
    if [ ! -d "$COMPONENT_PATH" ]; then
        echo ""
        print_error "========================================="
        print_error "  BUILD FAILED"
        print_error "========================================="
        print_error "xcodebuild exited 0 but output not found at: $COMPONENT_PATH"
        return 1
    fi

    echo ""
    print_success "========================================="
    print_success "  BUILD SUCCEEDED"
    print_success "========================================="
    print_info "Output: $COMPONENT_PATH"

    # Show binary info
    local binary_path="$COMPONENT_PATH/Contents/MacOS/$PROJECT_NAME"
    if [ -f "$binary_path" ]; then
        local size=$(du -h "$binary_path" | cut -f1)
        local archs=$(file "$binary_path" | grep -oE "(x86_64|arm64)" | tr '\n' ' ')
        print_info "Size: $size"
        print_info "Architectures: $archs"
    fi
    return 0
}

# Install the component to foobar2000
# Usage: do_install
do_install() {
    cd "$PROJECT_DIR"

    # Check if component exists
    if [ ! -d "$COMPONENT_PATH" ]; then
        print_error "Component not found at: $COMPONENT_PATH"
        print_error "Run build first"
        return 1
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

    # Clear macOS extended attributes and touch binary to invalidate dyld cache
    xattr -cr "$DEST_PATH" 2>/dev/null || true
    touch "$DEST_PATH/Contents/MacOS/$PROJECT_NAME" 2>/dev/null || true

    # Verify installation
    if [ -d "$DEST_PATH" ]; then
        print_success "Component installed successfully!"
        print_info "Location: $DEST_PATH"
        echo ""
        print_warning "Restart foobar2000 to load the component"
        return 0
    else
        print_error "Installation failed!"
        return 1
    fi
}

# Clean build artifacts
# Usage: do_clean
do_clean() {
    cd "$PROJECT_DIR"

    print_status "Cleaning $PROJECT_NAME..."

    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
        print_success "Removed build directory"
    fi

    if [ -d "$PROJECT_NAME.xcodeproj" ]; then
        rm -rf "$PROJECT_NAME.xcodeproj"
        print_success "Removed Xcode project"
    fi

    print_success "Clean complete"
}

# Parse common command line arguments
# Sets: BUILD_CONFIG, CLEAN_FIRST, REGENERATE, INSTALL_AFTER
parse_build_args() {
    CLEAN_FIRST=false
    REGENERATE=false
    INSTALL_AFTER=false

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
                return 1
                ;;
            *)
                print_error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    # Re-compute paths with possibly updated BUILD_CONFIG
    COMPONENT_PATH="$BUILD_DIR/$BUILD_CONFIG/$PROJECT_NAME.component"

    return 0
}

# Parse install arguments
parse_install_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)
                if [ "$2" != "Debug" ] && [ "$2" != "Release" ]; then
                    print_error "Invalid --config value: $2 (must be Debug or Release)"
                    return 1
                fi
                BUILD_CONFIG="$2"
                shift 2
                ;;
            --help|-h)
                return 1
                ;;
            *)
                print_error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    # Re-compute paths with possibly updated BUILD_CONFIG
    COMPONENT_PATH="$BUILD_DIR/$BUILD_CONFIG/$PROJECT_NAME.component"

    return 0
}
