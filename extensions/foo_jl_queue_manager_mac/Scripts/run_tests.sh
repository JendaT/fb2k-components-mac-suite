#!/bin/bash
#
# run_tests.sh - Compile and run unit tests for pure-logic Core models.
#
# The models under test are pure C++ or Foundation-only (no foobar2000
# SDK), so they compile standalone with clang in ~1s — no Xcode target or
# SDK needed. Invoked as a gating phase by build.sh; exits non-zero on
# any failure.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_BUILD_DIR="$PROJECT_DIR/build/tests"

mkdir -p "$TEST_BUILD_DIR"

echo "==> Compiling unit tests (QueueReorderPlanner)..."
clang++ -std=c++17 -O1 -Wall \
    "$PROJECT_DIR/Tests/QueueReorderPlannerTests.cpp" \
    "$PROJECT_DIR/src/Core/QueueReorderPlanner.cpp" \
    -o "$TEST_BUILD_DIR/reorder_tests"

echo "==> Compiling unit tests (QueueFormatting)..."
clang++ -std=c++17 -O1 -Wall \
    "$PROJECT_DIR/Tests/QueueFormattingTests.cpp" \
    "$PROJECT_DIR/src/Core/QueueFormatting.cpp" \
    -o "$TEST_BUILD_DIR/formatting_tests"

echo "==> Compiling unit tests (QueueDropParser)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/QueueDropParserTests.mm" \
    "$PROJECT_DIR/src/Core/QueueDropParser.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/dropparser_tests"

echo "==> Running unit tests..."
"$TEST_BUILD_DIR/reorder_tests"
"$TEST_BUILD_DIR/formatting_tests"
"$TEST_BUILD_DIR/dropparser_tests"
