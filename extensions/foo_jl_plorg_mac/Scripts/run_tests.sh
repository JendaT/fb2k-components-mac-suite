#!/bin/bash
#
# run_tests.sh - Compile and run unit tests for pure-logic Core models.
#
# The models under test are Foundation-only (no foobar2000 SDK), so they
# compile standalone with clang in ~1s — no Xcode target or SDK needed.
# Invoked as a gating phase by build.sh; exits non-zero on any failure.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_BUILD_DIR="$PROJECT_DIR/build/tests"

mkdir -p "$TEST_BUILD_DIR"

echo "==> Compiling unit tests (PathCodec)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/PathCodecTests.mm" \
    "$PROJECT_DIR/src/Core/PathCodec.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/pathcodec_tests"

echo "==> Compiling unit tests (TreeYamlCodec)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/TreeYamlCodecTests.mm" \
    "$PROJECT_DIR/src/Core/TreeYamlCodec.mm" \
    "$PROJECT_DIR/src/Core/TreeNode.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/treeyaml_tests"

echo "==> Compiling unit tests (TreeOps)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/TreeOpsTests.mm" \
    "$PROJECT_DIR/src/Core/TreeOps.mm" \
    "$PROJECT_DIR/src/Core/TreeNode.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/treeops_tests"

echo "==> Compiling unit tests (VolumeSyncLogic)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/VolumeSyncLogicTests.mm" \
    "$PROJECT_DIR/src/Core/VolumeSyncLogic.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/volumesync_tests"

echo "==> Running unit tests..."
"$TEST_BUILD_DIR/pathcodec_tests"
"$TEST_BUILD_DIR/treeyaml_tests"
"$TEST_BUILD_DIR/treeops_tests"
"$TEST_BUILD_DIR/volumesync_tests"
