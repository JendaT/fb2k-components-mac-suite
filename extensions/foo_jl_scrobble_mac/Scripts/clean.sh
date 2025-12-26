#!/bin/bash
#
# clean.sh - Clean build artifacts for foo_scrobble_mac
#

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "Cleaning build artifacts..."

# Remove build directory
if [ -d "build" ]; then
    rm -rf build
    echo "  Removed build/"
fi

# Remove Xcode derived data
if [ -d "DerivedData" ]; then
    rm -rf DerivedData
    echo "  Removed DerivedData/"
fi

# Remove xcuserdata
find . -name "xcuserdata" -type d -exec rm -rf {} + 2>/dev/null || true

echo "Clean complete."
