#!/bin/bash
#
# run_tests.sh - Compile and run unit tests for pure-logic Core modules.
#
# The modules under test are Foundation-only (no foobar2000 SDK), so they
# compile standalone with clang in ~1s — no Xcode target or SDK needed.
# Invoked as a gating phase by build.sh; exits non-zero on any failure.
#
# Tests run under ASan+UBSan: cheap at this scale and catches lifetime and
# index bugs in the parsing code paths.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_BUILD_DIR="$PROJECT_DIR/build/tests"

mkdir -p "$TEST_BUILD_DIR"

OBJCXX_FLAGS=(-x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall
              -fsanitize=address,undefined -fno-omit-frame-pointer)

echo "==> Compiling unit tests (ManifestParser)..."
clang++ "${OBJCXX_FLAGS[@]}" \
    "$PROJECT_DIR/Tests/ManifestParserTests.mm" \
    "$PROJECT_DIR/src/Core/ManifestParser.mm" \
    "$PROJECT_DIR/src/Core/TidalLog.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/manifest_parser_tests"

echo "==> Running unit tests..."
"$TEST_BUILD_DIR/manifest_parser_tests"
