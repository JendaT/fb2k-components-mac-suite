#!/bin/bash
#
# run_benchmark.sh - Compile and run the scroll-fill benchmark.
#
# Standalone (Foundation only, no SDK) like run_tests.sh, but built -O2 and
# NOT a gating phase of build.sh: numbers are machine-specific and compared
# manually before/after a change. Output is tee'd to build/benchmarks/ with
# a timestamped name, or to the file given as $1.
#
# Usage:
#   ./Scripts/run_benchmark.sh [output-file]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BENCH_BUILD_DIR="$PROJECT_DIR/build/benchmarks"

mkdir -p "$BENCH_BUILD_DIR"

OUT_FILE="${1:-$BENCH_BUILD_DIR/scroll-fill-$(date +%Y%m%d-%H%M%S).txt}"

echo "==> Compiling scroll-fill benchmark (-O2)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O2 -Wall \
    "$PROJECT_DIR/Tests/ScrollFillBenchmark.mm" \
    "$PROJECT_DIR/src/Core/PlaylistLayoutModel.mm" \
    -framework Foundation \
    -o "$BENCH_BUILD_DIR/scroll_fill_benchmark"

echo "==> Running benchmark (output: $OUT_FILE)..."
"$BENCH_BUILD_DIR/scroll_fill_benchmark" | tee "$OUT_FILE"
