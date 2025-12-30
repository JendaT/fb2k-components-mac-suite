#!/bin/zsh
# Creates a new foobar2000 macOS component with all necessary scaffolding
# Usage: ./Scripts/new-component.sh <component-name> "<Display Name>"
#
# Example: ./Scripts/new-component.sh lyrics "Lyrics Display"
#
# This script will:
#   1. Add version constant to shared/version.h
#   2. Add mapping to shared/sdk_config.rb
#   3. Add to Scripts/release_component.sh
#   4. Add to Scripts/package.sh
#   5. Add to Scripts/worktree-setup.sh
#   6. Add to Scripts/init-worktree-docs.sh
#   7. Update ~/.local/bin/fb2k-dev
#   8. Update ~/.zsh/completions/_fb2k-dev
#   9. Create extension directory structure
#   10. Create worktree
#   11. Add to README.md

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Parse arguments
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <component-name> \"<Display Name>\""
    echo ""
    echo "Example: $0 lyrics \"Lyrics Display\""
    echo ""
    echo "Component name should be lowercase with hyphens (e.g., lyrics, now-playing)"
    exit 1
fi

COMPONENT="$1"
DISPLAY_NAME="$2"

# Normalize: component name uses hyphens for worktree, underscores for code
COMPONENT_HYPHEN="$COMPONENT"
COMPONENT_UNDERSCORE="${COMPONENT//-/_}"
COMPONENT_UPPER=$(echo "$COMPONENT_UNDERSCORE" | tr '[:lower:]' '[:upper:]')

echo "=== Creating New Component: $DISPLAY_NAME ==="
echo ""
echo "  Component name:  $COMPONENT_HYPHEN"
echo "  Code name:       $COMPONENT_UNDERSCORE"
echo "  Version const:   ${COMPONENT_UPPER}_VERSION"
echo "  Directory:       foo_jl_${COMPONENT_UNDERSCORE}_mac"
echo "  Branch:          dev/$COMPONENT_HYPHEN"
echo ""

# Check if already exists
if grep -q "${COMPONENT_UPPER}_VERSION" "$PROJECT_ROOT/shared/version.h" 2>/dev/null; then
    echo "Error: Component '$COMPONENT' already exists in version.h"
    exit 1
fi

echo "Step 1: Adding to shared/version.h..."
# Append to end of file with comment
echo "
// ${DISPLAY_NAME}
#define ${COMPONENT_UPPER}_VERSION \"1.0.0\"
#define ${COMPONENT_UPPER}_VERSION_INT 100" >> "$PROJECT_ROOT/shared/version.h"

echo "Step 2: Adding to shared/sdk_config.rb..."
# Add to VERSION_MAP in Fb2kVersions
sed -i '' "/VERSION_MAP = {/a\\
    \"${COMPONENT_UNDERSCORE}\" => \"${COMPONENT_UPPER}_VERSION\",
" "$PROJECT_ROOT/shared/sdk_config.rb"

echo "Step 3: Adding to Scripts/release_component.sh..."
# Add to COMPONENT_MAP
sed -i '' "/COMPONENT_MAP=(/a\\
    [\"${COMPONENT_UNDERSCORE}\"]=\"foo_jl_${COMPONENT_UNDERSCORE}_mac\"\\
    [\"${COMPONENT_HYPHEN}\"]=\"foo_jl_${COMPONENT_UNDERSCORE}_mac\"
" "$SCRIPT_DIR/release_component.sh"

# Add to VERSION_MAP
sed -i '' "/typeset -A VERSION_MAP=(/a\\
    [\"${COMPONENT_UNDERSCORE}\"]=\"${COMPONENT_UPPER}_VERSION\"\\
    [\"${COMPONENT_HYPHEN}\"]=\"${COMPONENT_UPPER}_VERSION\"
" "$SCRIPT_DIR/release_component.sh"

# Add to DISPLAY_NAME_MAP
sed -i '' "/typeset -A DISPLAY_NAME_MAP=(/a\\
    [\"${COMPONENT_UNDERSCORE}\"]=\"${DISPLAY_NAME}\"\\
    [\"${COMPONENT_HYPHEN}\"]=\"${DISPLAY_NAME}\"
" "$SCRIPT_DIR/release_component.sh"

echo "Step 4: Adding to Scripts/package.sh..."
sed -i '' "/DIR_MAP=(/a\\
    [\"${COMPONENT_UNDERSCORE}\"]=\"jl_${COMPONENT_UNDERSCORE}\"\\
    [\"${COMPONENT_HYPHEN}\"]=\"jl_${COMPONENT_UNDERSCORE}\"
" "$SCRIPT_DIR/package.sh"

echo "Step 5: Adding to Scripts/worktree-setup.sh..."
sed -i '' "/COMPONENTS=(/a\\
    ${COMPONENT_HYPHEN}
" "$SCRIPT_DIR/worktree-setup.sh"

echo "Step 6: Adding to Scripts/init-worktree-docs.sh..."
sed -i '' "/DISPLAY_NAMES=(/a\\
    [${COMPONENT_HYPHEN}]=\"${DISPLAY_NAME}\"
" "$SCRIPT_DIR/init-worktree-docs.sh"

echo "Step 7: Updating ~/.local/bin/fb2k-dev..."
sed -i '' "/echo \"  playback-controls/a\\
    echo \"  ${COMPONENT_HYPHEN}$(printf '%*s' $((17 - ${#COMPONENT_HYPHEN})) '')- ${DISPLAY_NAME}\"
" ~/.local/bin/fb2k-dev

echo "Step 8: Updating ~/.zsh/completions/_fb2k-dev..."
sed -i '' "/\"playback-controls:/a\\
        \"${COMPONENT_HYPHEN}:${DISPLAY_NAME}\"
" ~/.zsh/completions/_fb2k-dev

echo "Step 9: Creating extension directory structure..."
EXT_DIR="$PROJECT_ROOT/extensions/foo_jl_${COMPONENT_UNDERSCORE}_mac"
mkdir -p "$EXT_DIR"/{src/{Core,UI,Integration},Resources,Scripts,build}

# Create basic files
cat > "$EXT_DIR/README.md" << EOF
# foo_jl_${COMPONENT_UNDERSCORE}

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/${COMPONENT_UNDERSCORE}.md)** | **[Changelog](CHANGELOG.md)**

---

${DISPLAY_NAME} for foobar2000 macOS.

## Requirements

- foobar2000 v2.x for macOS
- macOS 11.0 or later

## Building

\`\`\`bash
ruby Scripts/generate_xcode_project.rb
./Scripts/build.sh
./Scripts/install.sh
\`\`\`
EOF

cat > "$EXT_DIR/CHANGELOG.md" << EOF
# Changelog

All notable changes to ${DISPLAY_NAME} will be documented in this file.

## [1.0.0] - $(date +%Y-%m-%d)

### Initial Release
- Initial implementation
EOF

# Create placeholder scripts
cat > "$EXT_DIR/Scripts/build.sh" << 'EOF'
#!/bin/zsh
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$EXT_DIR"
PROJECT_FILE=$(ls -d *.xcodeproj 2>/dev/null | head -1)
if [ -z "$PROJECT_FILE" ]; then
    echo "Error: No Xcode project found. Run generate_xcode_project.rb first."
    exit 1
fi
xcodebuild -project "$PROJECT_FILE" -configuration Release build
EOF
chmod +x "$EXT_DIR/Scripts/build.sh"

cat > "$EXT_DIR/Scripts/install.sh" << EOF
#!/bin/zsh
set -e
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
EXT_DIR="\$(dirname "\$SCRIPT_DIR")"
COMPONENT="foo_jl_${COMPONENT_UNDERSCORE}.component"
BUILD_DIR="\$EXT_DIR/build/Release"
INSTALL_DIR="\$HOME/Library/foobar2000-v2/user-components/foo_jl_${COMPONENT_UNDERSCORE}"

if [ ! -d "\$BUILD_DIR/\$COMPONENT" ]; then
    echo "Error: Build not found at \$BUILD_DIR/\$COMPONENT"
    echo "Run ./Scripts/build.sh first"
    exit 1
fi

mkdir -p "\$INSTALL_DIR"
rm -rf "\$INSTALL_DIR/\$COMPONENT"
cp -R "\$BUILD_DIR/\$COMPONENT" "\$INSTALL_DIR/"
echo "Installed to \$INSTALL_DIR/\$COMPONENT"
EOF
chmod +x "$EXT_DIR/Scripts/install.sh"

echo "Step 10: Creating worktree..."
WORKTREE_DIR="$HOME/Projects/Foobar2000-worktrees/$COMPONENT_HYPHEN"
if [ ! -d "$WORKTREE_DIR" ]; then
    cd "$PROJECT_ROOT"
    git worktree add "$WORKTREE_DIR" -b "dev/$COMPONENT_HYPHEN" main

    # Symlink SDK
    if [ -d "$PROJECT_ROOT/SDK-2025-03-07" ]; then
        ln -s "$PROJECT_ROOT/SDK-2025-03-07" "$WORKTREE_DIR/SDK-2025-03-07"
    fi

    # Symlink shared
    if [ -d "$PROJECT_ROOT/shared" ]; then
        ln -s "$PROJECT_ROOT/shared" "$WORKTREE_DIR/shared"
    fi
fi

# Create CLAUDE.md and BACKLOG.md in worktree
"$SCRIPT_DIR/init-worktree-docs.sh" 2>/dev/null || true

echo ""
echo "=== Component Created Successfully ==="
echo ""
echo "Next steps:"
echo "  1. Create generate_xcode_project.rb in $EXT_DIR/Scripts/"
echo "  2. Implement the extension in $EXT_DIR/src/"
echo "  3. Add to README.md Extensions table"
echo "  4. Start development: fb2k-dev $COMPONENT_HYPHEN"
echo ""
echo "Extension directory: $EXT_DIR"
echo "Worktree: $WORKTREE_DIR"
