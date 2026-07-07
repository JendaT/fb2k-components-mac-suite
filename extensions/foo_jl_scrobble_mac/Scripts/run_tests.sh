#!/bin/bash
#
# run_tests.sh - Compile and run unit tests for pure-logic Core/Services code.
#
# The code under test is Foundation-only (no foobar2000 SDK), so it
# compiles standalone with clang in ~1s — no Xcode target or SDK needed.
# Invoked as a gating phase by build.sh; exits non-zero on any failure.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_BUILD_DIR="$PROJECT_DIR/build/tests"

mkdir -p "$TEST_BUILD_DIR"

echo "==> Compiling unit tests (ScrobbleRules)..."
clang++ -std=c++17 -O1 -Wall \
    "$PROJECT_DIR/Tests/ScrobbleRulesTests.cpp" \
    -o "$TEST_BUILD_DIR/scrobble_rules_tests"

echo "==> Compiling unit tests (PlaybackTracker)..."
clang++ -std=c++17 -O1 -Wall \
    "$PROJECT_DIR/Tests/PlaybackTrackerTests.cpp" \
    -o "$TEST_BUILD_DIR/playback_tracker_tests"

echo "==> Compiling unit tests (Model parsing)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/ModelParsingTests.mm" \
    "$PROJECT_DIR/src/Core/RecentTrack.mm" \
    "$PROJECT_DIR/src/Core/TopAlbum.mm" \
    "$PROJECT_DIR/src/Core/ScrobbleTrack.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/model_parsing_tests"

echo "==> Compiling unit tests (RateLimiter)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/RateLimiterTests.mm" \
    "$PROJECT_DIR/src/Services/RateLimiter.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/rate_limiter_tests"

echo "==> Running unit tests..."
"$TEST_BUILD_DIR/scrobble_rules_tests"
"$TEST_BUILD_DIR/playback_tracker_tests"
"$TEST_BUILD_DIR/model_parsing_tests"
"$TEST_BUILD_DIR/rate_limiter_tests"
