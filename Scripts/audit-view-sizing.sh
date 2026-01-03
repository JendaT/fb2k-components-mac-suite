#!/bin/zsh
# audit-view-sizing.sh - Find views that may cause container limiting
#
# Usage: ./Scripts/audit-view-sizing.sh [extension]
#        ./Scripts/audit-view-sizing.sh              # Audit all extensions
#        ./Scripts/audit-view-sizing.sh simplaylist  # Audit specific extension
#
# Checks for:
# 1. intrinsicContentSize implementations that return actual dimensions
# 2. Missing setContentHuggingPriority calls
# 3. Missing setContentCompressionResistancePriority calls
# 4. High priority values (750, 1000, NSLayoutPriorityDefaultHigh, NSLayoutPriorityRequired)

# Don't exit on error - we want to continue auditing all extensions
# set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTENSIONS_DIR="$REPO_ROOT/extensions"

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() { echo "${CYAN}=== $1 ===${NC}"; }
print_error() { echo "${RED}✗ $1${NC}"; }
print_warning() { echo "${YELLOW}⚠ $1${NC}"; }
print_ok() { echo "${GREEN}✓ $1${NC}"; }

ISSUES_FOUND=0

audit_file() {
    local file="$1"
    local basename=$(basename "$file")
    local relative_path="${file#$REPO_ROOT/}"
    local file_has_issues=0

    # Skip non-view files
    if [[ ! "$basename" =~ (View|Controller)\.mm$ ]]; then
        return 0
    fi

    # Check if file has intrinsicContentSize
    local has_intrinsic
    has_intrinsic=$(grep -c "intrinsicContentSize" "$file" 2>/dev/null) || has_intrinsic=0

    if [[ "$has_intrinsic" -gt 0 ]]; then
        # Check if it returns actual dimensions (bad) vs NSViewNoIntrinsicMetric (good)
        local returns_metric
        returns_metric=$(grep -c "NSViewNoIntrinsicMetric\|return NSMakeSize(-1\|return NSMakeSize(NSViewNoIntrinsicMetric" "$file" 2>/dev/null) || returns_metric=0
        local returns_actual
        returns_actual=$(grep "intrinsicContentSize" -A 5 "$file" | grep -c "return NSMakeSize(" 2>/dev/null) || returns_actual=0

        if [[ "$returns_actual" -gt 0 && "$returns_metric" -eq 0 ]]; then
            print_error "$relative_path: intrinsicContentSize returns actual dimensions"
            grep -n "intrinsicContentSize" -A 5 "$file" | head -10 | sed 's/^/    /'
            file_has_issues=1
            ISSUES_FOUND=$((ISSUES_FOUND + 1))
        fi
    fi

    # Check for missing priority settings
    local has_hugging
    has_hugging=$(grep -c "setContentHuggingPriority" "$file" 2>/dev/null) || has_hugging=0
    local has_compression
    has_compression=$(grep -c "setContentCompressionResistancePriority" "$file" 2>/dev/null) || has_compression=0

    # Only check main view files
    if [[ "$basename" =~ View\.mm$ ]] && [[ "$has_intrinsic" -gt 0 || "$basename" =~ (Playlist|Waveform|Album|Queue|Scrobble|Biography) ]]; then
        if [[ "$has_hugging" -eq 0 ]]; then
            print_warning "$relative_path: No setContentHuggingPriority calls found"
            file_has_issues=1
            ISSUES_FOUND=$((ISSUES_FOUND + 1))
        fi

        if [[ "$has_compression" -eq 0 ]]; then
            print_warning "$relative_path: No setContentCompressionResistancePriority calls found"
            file_has_issues=1
            ISSUES_FOUND=$((ISSUES_FOUND + 1))
        fi
    fi

    # Check for high priority values
    local high_priorities=$(grep -n "NSLayoutPriorityDefaultHigh\|NSLayoutPriorityRequired\|priority.*750\|priority.*1000\|Priority:750\|Priority:1000" "$file" 2>/dev/null | grep -v "// intentional" | grep -v "//" || true)

    if [[ -n "$high_priorities" ]]; then
        # Filter out constraint priorities (which are OK) vs hugging/compression (which are bad)
        local bad_priorities=$(echo "$high_priorities" | grep -i "hugging\|compression" || true)
        if [[ -n "$bad_priorities" ]]; then
            print_error "$relative_path: High hugging/compression priority found"
            echo "$bad_priorities" | sed 's/^/    /'
            file_has_issues=1
            ISSUES_FOUND=$((ISSUES_FOUND + 1))
        fi
    fi

    return $file_has_issues
}

audit_extension() {
    local ext_path="$1"
    local ext_name=$(basename "$ext_path")
    local ext_issues=0

    print_header "$ext_name"

    # Find all .mm files in UI directory
    local ui_files=$(find "$ext_path" -path "*/UI/*.mm" -type f 2>/dev/null || true)

    if [[ -z "$ui_files" ]]; then
        echo "  No UI files found"
        return 0
    fi

    while IFS= read -r file; do
        audit_file "$file" || ((ext_issues++))
    done <<< "$ui_files"

    if [[ $ext_issues -eq 0 ]]; then
        print_ok "No issues found"
    fi

    echo ""
    return $ext_issues
}

# Main
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║           View Sizing Audit - Container Limiting Check         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if [[ -n "$1" ]]; then
    # Audit specific extension
    EXT_NAME="$1"
    EXT_PATH="$EXTENSIONS_DIR/foo_jl_${EXT_NAME}_mac"
    if [[ ! -d "$EXT_PATH" ]]; then
        EXT_PATH="$EXTENSIONS_DIR/foo_jl_${EXT_NAME}"
    fi
    if [[ ! -d "$EXT_PATH" ]]; then
        print_error "Extension not found: $EXT_NAME"
        echo "Looked in:"
        echo "  - $EXTENSIONS_DIR/foo_jl_${EXT_NAME}_mac"
        echo "  - $EXTENSIONS_DIR/foo_jl_${EXT_NAME}"
        exit 1
    fi
    audit_extension "$EXT_PATH"
else
    # Audit all extensions
    for ext_path in "$EXTENSIONS_DIR"/foo_jl_*; do
        if [[ -d "$ext_path" ]]; then
            audit_extension "$ext_path"
        fi
    done
fi

echo "────────────────────────────────────────────────────────────────"
if [[ $ISSUES_FOUND -eq 0 ]]; then
    print_ok "Audit complete: No issues found"
else
    print_error "Audit complete: $ISSUES_FOUND issue(s) found"
    echo ""
    echo "See knowledge_base/10_VIEW_SIZING_AND_CONTAINER_CONSTRAINTS.md for fix patterns"
fi
echo ""

exit $ISSUES_FOUND
