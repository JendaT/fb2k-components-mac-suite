#!/bin/zsh
#
# Aggregate Code Review Findings
#
# Usage: ./aggregate_reviews.sh <component>
#
# Combines all 10 pass outputs into a single summary document
# for prioritized fix planning.
#

set -e

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
OUTPUT_DIR="$PROJECT_ROOT/code_reviews"

if [[ -z "$1" ]]; then
    echo "Usage: $0 <component>"
    echo ""
    echo "Components: simplaylist, plorg, waveform, scrobble"
    exit 1
fi

COMPONENT="$1"
REVIEW_DIR="$OUTPUT_DIR/$COMPONENT"

if [[ ! -d "$REVIEW_DIR" ]]; then
    echo "Error: No reviews found for '$COMPONENT'"
    echo "Run ./run_code_review.sh $COMPONENT first"
    exit 1
fi

SUMMARY_FILE="$REVIEW_DIR/SUMMARY.md"

echo "# $COMPONENT Code Review Summary" > "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"
echo "Generated: $(date -Iseconds)" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

# Collect all pass files (exclude prompts)
PASS_FILES=(${(f)"$(ls "$REVIEW_DIR"/pass_*.md 2>/dev/null | grep -v prompt | sort)"})

if [[ ${#PASS_FILES[@]} -eq 0 ]]; then
    echo "No pass output files found in $REVIEW_DIR"
    echo "Expected files like: pass_01_Memory_Management.md"
    exit 1
fi

echo "## Passes Completed" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

for file in "${PASS_FILES[@]}"; do
    name="${file:t:r}"
    echo "- [x] $name" >> "$SUMMARY_FILE"
done

echo "" >> "$SUMMARY_FILE"
echo "---" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

# Concatenate all findings
echo "## All Findings" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

for file in "${PASS_FILES[@]}"; do
    echo "" >> "$SUMMARY_FILE"
    cat "$file" >> "$SUMMARY_FILE"
    echo "" >> "$SUMMARY_FILE"
    echo "---" >> "$SUMMARY_FILE"
done

echo ""
echo "Summary created: $SUMMARY_FILE"
echo ""
echo "Next steps:"
echo "1. Review $SUMMARY_FILE"
echo "2. Deduplicate overlapping findings"
echo "3. Prioritize by severity"
echo "4. Create fix tasks"
