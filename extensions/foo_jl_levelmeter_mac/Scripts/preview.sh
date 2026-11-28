#!/bin/bash
#
# preview.sh - Render the meter to PNG files without foobar2000.
#
# Builds Tools/MeterPreview.mm against the SDK-free Core and renderer and
# writes a set of panel sizes and styles to the output directory.
#
# Usage: ./Scripts/preview.sh [output-dir]   (default: build/preview)
#        ./Scripts/preview.sh --stack        check the draw layers stack up to the full picture
#        ./Scripts/preview.sh --time         time each draw pass

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="${1:-}"
OUT_DIR="$PROJECT_DIR/build/preview"
[[ -n "$MODE" && "$MODE" != --* ]] && OUT_DIR="$MODE"
BIN="$PROJECT_DIR/build/tests/MeterPreview"

mkdir -p "$(dirname "$BIN")"
[[ "$MODE" == --* ]] || mkdir -p "$OUT_DIR"
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tools/MeterPreview.mm" \
    "$PROJECT_DIR/src/UI/MeterRenderer.mm" \
    "$PROJECT_DIR"/src/Core/*.cpp \
    -framework Cocoa \
    -o "$BIN"
if [[ "$MODE" == --* ]]; then
    "$BIN" "$MODE"
else
    "$BIN" "$OUT_DIR"
fi
