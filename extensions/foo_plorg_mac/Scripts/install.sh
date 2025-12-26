#!/bin/bash
# Install script for foo_plorg_mac

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_NAME="foo_plorg"
CONFIGURATION="${1:-Release}"

# foobar2000 v2 component path (correct location)
FB2K_USER_COMPONENTS="$HOME/Library/foobar2000-v2/user-components"

COMPONENT="$PROJECT_DIR/build/$CONFIGURATION/$PROJECT_NAME.component"

if [ ! -d "$COMPONENT" ]; then
    echo "Component not found. Building first..."
    "$SCRIPT_DIR/build.sh" "$CONFIGURATION"
fi

# Create the component directory structure: user-components/foo_plorg/foo_plorg.component
INSTALL_DIR="$FB2K_USER_COMPONENTS/$PROJECT_NAME"

echo "Installing $PROJECT_NAME.component to $INSTALL_DIR..."

# Remove old version
rm -rf "$INSTALL_DIR"

# Create directory and copy
mkdir -p "$INSTALL_DIR"
cp -R "$COMPONENT" "$INSTALL_DIR/"

echo ""
echo "Installation complete!"
echo "Installed to: $INSTALL_DIR/$PROJECT_NAME.component"
echo "Restart foobar2000 to load the component."
