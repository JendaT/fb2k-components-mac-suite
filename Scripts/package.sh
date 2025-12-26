#!/bin/bash
#
# Package a foobar2000 macOS extension as .fb2k-component
#
# Usage: ./package.sh <extension_name>
# Example: ./package.sh simplaylist
#
# Creates foo_<name>.fb2k-component in the current directory
#

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <extension_name>"
    echo "Example: $0 simplaylist"
    echo ""
    echo "Available extensions:"
    ls -d extensions/foo_*_mac 2>/dev/null | xargs -I{} basename {} | sed 's/foo_//;s/_mac//'
    exit 1
fi

NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
EXT_DIR="$PROJECT_ROOT/extensions/foo_${NAME}_mac"
BUILD_DIR="$EXT_DIR/build/Release"
COMPONENT_NAME="foo_${NAME}.component"
OUTPUT_FILE="foo_${NAME}.fb2k-component"

# Check extension exists
if [ ! -d "$EXT_DIR" ]; then
    echo "Error: Extension directory not found: $EXT_DIR"
    exit 1
fi

# Check build exists
if [ ! -d "$BUILD_DIR/$COMPONENT_NAME" ]; then
    echo "Error: Built component not found: $BUILD_DIR/$COMPONENT_NAME"
    echo "Run ./Scripts/build.sh in $EXT_DIR first"
    exit 1
fi

# Create temp directory for packaging
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Create mac subdirectory structure (required format)
mkdir -p "$TEMP_DIR/mac"
cp -R "$BUILD_DIR/$COMPONENT_NAME" "$TEMP_DIR/mac/"

# Create the fb2k-component archive
cd "$TEMP_DIR"
zip -r "$PROJECT_ROOT/$OUTPUT_FILE" mac/

echo ""
echo "Created: $OUTPUT_FILE"
echo "Size: $(du -h "$PROJECT_ROOT/$OUTPUT_FILE" | cut -f1)"
echo ""
echo "Ready for distribution via GitHub Releases or foobar2000.org"
