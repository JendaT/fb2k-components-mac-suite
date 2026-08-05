#!/bin/bash
#
# run_tests.sh - Compile and run unit tests for pure-logic Core models.
#
# The models under test are Foundation-only (no foobar2000 SDK), so they
# compile standalone with clang in ~1s — no Xcode target or SDK needed.
# Compilation runs in parallel; test execution stays serial.
# Invoked as a gating phase by build.sh; exits non-zero on any failure.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_BUILD_DIR="$PROJECT_DIR/build/tests"

mkdir -p "$TEST_BUILD_DIR"

echo "==> Compiling unit tests (PlorgPathCodec, PlorgTreeYamlCodec, TreeNode format, PlorgTreeOps, PlorgVolumeSyncLogic)..."

clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/PathCodecTests.mm" \
    "$PROJECT_DIR/src/Core/PlorgPathCodec.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/pathcodec_tests" &
PATHCODEC_PID=$!

clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/TreeYamlCodecTests.mm" \
    "$PROJECT_DIR/src/Core/PlorgTreeYamlCodec.mm" \
    "$PROJECT_DIR/src/Core/TreeNode.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/treeyaml_tests" &
TREEYAML_PID=$!

clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/TreeNodeFormatTests.mm" \
    "$PROJECT_DIR/src/Core/TreeNode.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/treenode_tests" &
TREENODE_PID=$!

clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/TreeOpsTests.mm" \
    "$PROJECT_DIR/src/Core/PlorgTreeOps.mm" \
    "$PROJECT_DIR/src/Core/TreeNode.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/treeops_tests" &
TREEOPS_PID=$!

clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/VolumeSyncLogicTests.mm" \
    "$PROJECT_DIR/src/Core/PlorgVolumeSyncLogic.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/volumesync_tests" &
VOLUMESYNC_PID=$!

COMPILE_FAILED=0
wait "$PATHCODEC_PID"  || { echo "ERROR: PlorgPathCodec tests failed to compile" >&2;      COMPILE_FAILED=1; }
wait "$TREEYAML_PID"   || { echo "ERROR: PlorgTreeYamlCodec tests failed to compile" >&2;  COMPILE_FAILED=1; }
wait "$TREENODE_PID"   || { echo "ERROR: TreeNode format tests failed to compile" >&2;     COMPILE_FAILED=1; }
wait "$TREEOPS_PID"    || { echo "ERROR: PlorgTreeOps tests failed to compile" >&2;        COMPILE_FAILED=1; }
wait "$VOLUMESYNC_PID" || { echo "ERROR: PlorgVolumeSyncLogic tests failed to compile" >&2; COMPILE_FAILED=1; }

if [ "$COMPILE_FAILED" -ne 0 ]; then
    echo "ERROR: unit test compilation failed" >&2
    exit 1
fi

echo "==> Running unit tests..."
"$TEST_BUILD_DIR/pathcodec_tests"
"$TEST_BUILD_DIR/treeyaml_tests"
"$TEST_BUILD_DIR/treenode_tests"
"$TEST_BUILD_DIR/treeops_tests"
"$TEST_BUILD_DIR/volumesync_tests"
