#!/bin/zsh
# audit-memory.sh - Scan for common memory leak patterns in Objective-C/C++ code
#
# Usage: ./Scripts/audit-memory.sh [extension_dir]
# Example: ./Scripts/audit-memory.sh extensions/foo_jl_simplaylist_mac

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

TARGET_DIR="${1:-$REPO_ROOT/extensions}"

echo "=== Memory Leak Pattern Audit ==="
echo "Target: $TARGET_DIR"
echo ""

ISSUES=0
WARNINGS=0

check_pattern() {
    local pattern="$1"
    local description="$2"
    local severity="$3"  # error or warning
    local context="${4:-0}"

    local results=$(grep -rn --include="*.mm" --include="*.m" --include="*.h" -E "$pattern" "$TARGET_DIR" 2>/dev/null || true)

    if [[ -n "$results" ]]; then
        if [[ "$severity" == "error" ]]; then
            echo "${RED}[LEAK RISK]${NC} $description"
            ((ISSUES++))
        else
            echo "${YELLOW}[WARNING]${NC} $description"
            ((WARNINGS++))
        fi
        echo "$results" | head -10 | while read -r line; do
            echo "  $line"
        done
        local count=$(echo "$results" | wc -l | tr -d ' ')
        if (( count > 10 )); then
            echo "  ... and $((count - 10)) more"
        fi
        echo ""
    fi
}

check_missing_pair() {
    local add_pattern="$1"
    local remove_pattern="$2"
    local description="$3"

    local add_count=$(grep -r --include="*.mm" --include="*.m" -c "$add_pattern" "$TARGET_DIR" 2>/dev/null | awk -F: '{sum += $2} END {print sum}')
    local remove_count=$(grep -r --include="*.mm" --include="*.m" -c "$remove_pattern" "$TARGET_DIR" 2>/dev/null | awk -F: '{sum += $2} END {print sum}')

    add_count=${add_count:-0}
    remove_count=${remove_count:-0}

    if (( add_count > remove_count )); then
        echo "${RED}[LEAK RISK]${NC} $description"
        echo "  Found $add_count adds but only $remove_count removes"
        ((ISSUES++))
        echo ""
    elif (( add_count > 0 )); then
        echo "${GREEN}[OK]${NC} $description: $add_count adds, $remove_count removes"
    fi
}

echo "--- Notification Observers ---"
check_missing_pair "addObserver:" "removeObserver:" "NSNotificationCenter observer balance"

echo ""
echo "--- Timers ---"
check_missing_pair "scheduledTimerWith\|repeats:YES" "invalidate" "NSTimer invalidation"
check_pattern "NSTimer.*repeats:\s*YES" "Repeating timers (must invalidate in dealloc)" "warning"

echo ""
echo "--- Block Retain Cycles ---"
check_pattern "\^[^}]*\bself\b" "Blocks capturing 'self' (potential retain cycle)" "warning"
check_pattern "__strong.*self" "Strong self in block without weakSelf pattern" "warning"

echo ""
echo "--- Image/Data Caching ---"
check_pattern "NSMutableDictionary\s*\*.*[Cc]ache" "Mutable dictionary cache (check for size limits)" "warning"
check_pattern "NSMutableArray\s*\*.*[Cc]ache" "Mutable array cache (check for size limits)" "warning"
check_pattern "NSCache" "NSCache usage (good - has auto-eviction)" "info"
check_pattern "imageNamed:" "imageNamed: caches images permanently" "warning"
check_pattern "\[NSImage\s+alloc\].*init" "NSImage alloc/init (check if released)" "warning"

echo ""
echo "--- Unbounded Collections ---"
check_pattern "addObject:.*[Cc]ache\|insertObject:.*[Cc]ache" "Adding to cache without removal" "warning"
check_pattern "setObject:.*forKey:.*[Cc]ache" "Setting cache entries (check eviction policy)" "warning"

echo ""
echo "--- KVO Observers ---"
check_missing_pair "addObserver:.*forKeyPath:" "removeObserver:.*forKeyPath:" "KVO observer balance"

echo ""
echo "--- Dealloc Implementation ---"
local dealloc_count=$(grep -r --include="*.mm" --include="*.m" -c "^\s*-\s*(void)dealloc" "$TARGET_DIR" 2>/dev/null | awk -F: '{sum += $2} END {print sum}')
local class_count=$(grep -r --include="*.mm" --include="*.m" -c "@implementation" "$TARGET_DIR" 2>/dev/null | awk -F: '{sum += $2} END {print sum}')
dealloc_count=${dealloc_count:-0}
class_count=${class_count:-0}

echo "Classes with @implementation: $class_count"
echo "Classes with dealloc: $dealloc_count"
if (( class_count > dealloc_count + 5 )); then
    echo "${YELLOW}[WARNING]${NC} Many classes missing dealloc - may need cleanup code"
    ((WARNINGS++))
fi

echo ""
echo "--- C++ Allocations ---"
check_pattern "\bnew\s+\w+\[" "C++ array allocation (check for delete[])" "warning"
check_pattern "\bmalloc\s*\(" "malloc usage (check for free)" "warning"
check_pattern "std::vector|std::map|std::unordered_map" "STL containers (check if cleared appropriately)" "info"

echo ""
echo "--- Dispatch/GCD ---"
check_pattern "dispatch_source_create" "Dispatch sources (must cancel)" "warning"
check_pattern "dispatch_queue_create" "Custom dispatch queues" "info"

echo ""
echo "=========================================="
echo "Summary: ${RED}$ISSUES issues${NC}, ${YELLOW}$WARNINGS warnings${NC}"
echo ""

if (( ISSUES > 0 )); then
    echo "Run with Instruments.app Leaks template for definitive leak detection."
    exit 1
fi
