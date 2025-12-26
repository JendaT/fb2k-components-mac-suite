#!/bin/bash
# Build script for foo_jl_plorg_mac

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_NAME="foo_jl_plorg"

cd "$PROJECT_DIR"

# Configuration
CONFIGURATION="${1:-Release}"

echo "Building $PROJECT_NAME ($CONFIGURATION)..."

# Check if Xcode project exists
if [ ! -d "$PROJECT_NAME.xcodeproj" ]; then
    echo "Xcode project not found. Generating..."
    ruby Scripts/generate_xcode_project.rb
fi

# Build
xcodebuild -project "$PROJECT_NAME.xcodeproj" \
    -scheme "$PROJECT_NAME" \
    -configuration "$CONFIGURATION" \
    build \
    CONFIGURATION_BUILD_DIR="$PROJECT_DIR/build/$CONFIGURATION"

echo ""
echo "Build complete!"
echo "Component: $PROJECT_DIR/build/$CONFIGURATION/$PROJECT_NAME.component"
