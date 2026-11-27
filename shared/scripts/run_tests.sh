#!/bin/bash
#
# run_tests.sh - Compile and run unit tests for the header-only shared code.
# Auto-discovers shared/Tests/*Tests.cpp (one binary each), builds with
# ASan+UBSan, exits non-zero on any failure.
#
# Usage: shared/scripts/run_tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_BUILD_DIR="$SHARED_DIR/build/tests"
mkdir -p "$TEST_BUILD_DIR"

BINARIES=()
for test_file in "$SHARED_DIR"/Tests/*Tests.cpp; do
    [ -e "$test_file" ] || continue
    name="$(basename "${test_file%.*}")"
    out="$TEST_BUILD_DIR/$name"
    echo "==> Compiling $name..."
    clang++ -std=c++17 -O1 -Wall -fsanitize=address,undefined \
        -fno-sanitize-recover=undefined -fno-omit-frame-pointer \
        "$test_file" -o "$out"
    BINARIES+=("$out")
done

if [ "${#BINARIES[@]}" -eq 0 ]; then
    echo "ERROR: no tests discovered in $SHARED_DIR/Tests" >&2
    exit 1
fi

echo "==> Running unit tests..."
for bin in "${BINARIES[@]}"; do
    "$bin"
done
