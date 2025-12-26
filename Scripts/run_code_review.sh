#!/bin/zsh
#
# Multi-Pass Code Review Runner
#
# Usage:
#   ./run_code_review.sh <component> [pass_number]
#   ./run_code_review.sh all              # Review all components
#   ./run_code_review.sh simplaylist 1    # Run specific pass
#   ./run_code_review.sh simplaylist      # Run all 10 passes
#
# Each pass runs in an independent Claude Code session to avoid bias.
#

set -e

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
OUTPUT_DIR="$PROJECT_ROOT/code_reviews"

# Component name mapping
typeset -A COMPONENT_DIRS
COMPONENT_DIRS=(
    simplaylist "foo_jl_simplaylist_mac"
    plorg "foo_jl_plorg_mac"
    waveform "foo_jl_wave_seekbar_mac"
    scrobble "foo_jl_scrobble_mac"
)

# Review focus areas
PASS_NAMES=(
    "Memory Management"
    "Thread Safety"
    "Error Handling"
    "SDK Contract Compliance"
    "Performance"
    "UI/UX Consistency"
    "Configuration Persistence"
    "Code Structure"
    "Security"
    "Documentation & Logging"
)

PASS_PROMPTS=(
    "Focus ONLY on Memory Management: retain cycles, strong reference cycles in blocks, ARC bridging issues, missing weak references, observer removal in dealloc, proper cleanup."
    "Focus ONLY on Thread Safety: main thread UI access, race conditions on shared state, foobar2000 callback thread assumptions, potential deadlocks, atomic operations."
    "Focus ONLY on Error Handling: nil/null checks, optional unwrapping safety, API failure handling, graceful degradation, user-visible vs silent errors."
    "Focus ONLY on SDK Contract Compliance: callback registration/unregistration lifecycle, service_ptr usage, GUID correctness, component version macros, menu registration."
    "Focus ONLY on Performance: unnecessary redraws/reloads, expensive operations in loops, caching opportunities, lazy initialization, hot path optimizations."
    "Focus ONLY on UI/UX Consistency: foobar2000 native styling, dark mode support, keyboard accessibility, resize handling, context menu consistency."
    "Focus ONLY on Configuration Persistence: configStore key naming, default values, settings migration, validation, preference UI synchronization."
    "Focus ONLY on Code Structure: single responsibility, method complexity, naming clarity, code duplication, dead code removal opportunities."
    "Focus ONLY on Security: user input sanitization, URL/path validation, credential handling, injection risks, sensitive data exposure."
    "Focus ONLY on Documentation & Logging: critical algorithm docs, public API comments, console log verbosity, debug info exposure, license headers."
)

show_help() {
    echo "Multi-Pass Code Review Runner"
    echo ""
    echo "Usage:"
    echo "  $0 <component> [pass_number]"
    echo "  $0 all"
    echo ""
    echo "Components:"
    echo "  simplaylist  - SimPlaylist (playlist view)"
    echo "  plorg        - Playlist Organizer"
    echo "  waveform     - Waveform Seekbar"
    echo "  scrobble     - Last.fm Scrobbler"
    echo "  all          - Review all components"
    echo ""
    echo "Passes (1-10):"
    for i in {1..10}; do
        printf "  %2d. %s\n" $i "${PASS_NAMES[$i]}"
    done
    echo ""
    echo "Examples:"
    echo "  $0 simplaylist 1    # Run Memory Management pass on SimPlaylist"
    echo "  $0 plorg            # Run all 10 passes on Playlist Organizer"
    echo "  $0 all              # Run all passes on all components"
}

run_pass() {
    local component="$1"
    local pass_num="$2"
    local component_dir="${COMPONENT_DIRS[$component]}"
    local pass_name="${PASS_NAMES[$pass_num]}"
    local pass_prompt="${PASS_PROMPTS[$pass_num]}"

    if [[ -z "$component_dir" ]]; then
        echo "Error: Unknown component '$component'"
        exit 1
    fi

    local ext_path="$PROJECT_ROOT/extensions/$component_dir"
    if [[ ! -d "$ext_path" ]]; then
        echo "Error: Extension directory not found: $ext_path"
        exit 1
    fi

    # Create output directory
    local review_dir="$OUTPUT_DIR/$component"
    mkdir -p "$review_dir"

    local safe_name="${pass_name// /_}"
    local output_file="$review_dir/pass_$(printf '%02d' $pass_num)_${safe_name}.md"

    echo ""
    echo "=============================================="
    echo "Component: $component ($component_dir)"
    echo "Pass $pass_num: $pass_name"
    echo "Output: $output_file"
    echo "=============================================="
    echo ""

    # Build the review prompt
    local full_prompt="Perform a focused code review of the foobar2000 macOS component at extensions/$component_dir.

$pass_prompt

Instructions:
1. Read all source files in the component's src/ directory
2. List ALL findings with file:line references
3. Rate severity: Critical/High/Medium/Low
4. Provide specific fix recommendations with code examples
5. Reference knowledge_base/ patterns where applicable

Output format:
# Code Review: $component - Pass $pass_num: $pass_name

## Summary
- Files reviewed: X
- Issues found: Y

## Findings

### [Finding Title]
- **Severity**: Critical/High/Medium/Low
- **Location**: \`path/to/file.mm:123\`
- **Issue**: Description
- **Recommendation**: Fix suggestion

---

Be thorough. This is pass $pass_num of 10 independent reviews."

    # Save the prompt for reference
    echo "$full_prompt" > "$review_dir/pass_$(printf '%02d' $pass_num)_prompt.txt"

    echo "Prompt saved to: $review_dir/pass_$(printf '%02d' $pass_num)_prompt.txt"
    echo ""
    echo "To run this review pass in a fresh Claude Code session:"
    echo ""
    echo "  cat \"$review_dir/pass_$(printf '%02d' $pass_num)_prompt.txt\" | claude --print > \"$output_file\""
    echo ""
}

run_all_passes() {
    local component="$1"

    for pass in {1..10}; do
        run_pass "$component" "$pass"
        echo ""
    done
}

run_all_components() {
    for comp in simplaylist plorg waveform scrobble; do
        run_all_passes "$comp"
    done
}

# Main
if [[ -z "$1" ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_help
    exit 0
fi

mkdir -p "$OUTPUT_DIR"

if [[ "$1" == "all" ]]; then
    run_all_components
elif [[ -n "$2" ]]; then
    # Specific pass
    if [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 )) && (( $2 <= 10 )); then
        run_pass "$1" "$2"
    else
        echo "Error: Pass number must be 1-10"
        exit 1
    fi
else
    # All passes for one component
    run_all_passes "$1"
fi

echo ""
echo "=============================================="
echo "Review prompts generated in: $OUTPUT_DIR/"
echo ""
echo "To execute reviews, run each prompt in a fresh Claude Code session"
echo "for independent analysis without bias from previous passes."
echo "=============================================="
