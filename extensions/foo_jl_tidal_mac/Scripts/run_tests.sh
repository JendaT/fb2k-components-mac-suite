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

echo "==> Compiling unit tests (StreamResolutionPolicy)..."
clang++ "${OBJCXX_FLAGS[@]}" \
    "$PROJECT_DIR/Tests/StreamResolutionPolicyTests.mm" \
    "$PROJECT_DIR/src/Core/StreamResolutionPolicy.mm" \
    "$PROJECT_DIR/src/Core/TidalErrors.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/stream_resolution_policy_tests"

echo "==> Compiling unit tests (HTTPResponsePolicy)..."
clang++ "${OBJCXX_FLAGS[@]}" \
    "$PROJECT_DIR/Tests/HTTPResponsePolicyTests.mm" \
    "$PROJECT_DIR/src/Core/HTTPResponsePolicy.mm" \
    "$PROJECT_DIR/src/Core/TidalErrors.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/http_response_policy_tests"

echo "==> Compiling unit tests (URLUtils)..."
clang++ "${OBJCXX_FLAGS[@]}" \
    "$PROJECT_DIR/Tests/URLUtilsTests.mm" \
    "$PROJECT_DIR/src/Core/URLUtils.mm" \
    "$PROJECT_DIR/src/Core/TidalLog.mm" \
    "$PROJECT_DIR/src/Core/TidalErrors.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/url_utils_tests"

echo "==> Compiling unit tests (TidalSession)..."
clang++ "${OBJCXX_FLAGS[@]}" \
    "$PROJECT_DIR/Tests/TidalSessionTests.mm" \
    "$PROJECT_DIR/src/API/TidalSession.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/tidal_session_tests"

echo "==> Compiling unit tests (StreamCache)..."
clang++ "${OBJCXX_FLAGS[@]}" \
    "$PROJECT_DIR/Tests/StreamCacheTests.mm" \
    "$PROJECT_DIR/src/Core/StreamCache.mm" \
    "$PROJECT_DIR/src/Core/TidalModels.mm" \
    "$PROJECT_DIR/src/Core/ManifestParser.mm" \
    "$PROJECT_DIR/src/Core/TidalLog.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/stream_cache_tests"

echo "==> Running unit tests..."
"$TEST_BUILD_DIR/manifest_parser_tests"
"$TEST_BUILD_DIR/stream_resolution_policy_tests"
"$TEST_BUILD_DIR/http_response_policy_tests"
"$TEST_BUILD_DIR/url_utils_tests"
"$TEST_BUILD_DIR/tidal_session_tests"
"$TEST_BUILD_DIR/stream_cache_tests"
