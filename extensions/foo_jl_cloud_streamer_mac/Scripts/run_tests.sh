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

CXXFLAGS=(-x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall -framework Foundation)

echo "==> Compiling unit tests (URLUtils)..."
clang++ "${CXXFLAGS[@]}" \
    "$PROJECT_DIR/Tests/URLUtilsTests.mm" \
    "$PROJECT_DIR/src/Core/URLUtils.mm" \
    -o "$TEST_BUILD_DIR/url_tests"

echo "==> Compiling unit tests (CueSheet / TrackInfo)..."
clang++ "${CXXFLAGS[@]}" \
    "$PROJECT_DIR/Tests/CueSheetTests.mm" \
    "$PROJECT_DIR/src/Core/URLUtils.mm" \
    -o "$TEST_BUILD_DIR/cue_tests"

echo "==> Compiling unit tests (TrackTagMapper)..."
clang++ "${CXXFLAGS[@]}" \
    "$PROJECT_DIR/Tests/TrackTagMapperTests.mm" \
    "$PROJECT_DIR/src/Core/TrackTagMapper.mm" \
    "$PROJECT_DIR/src/Core/URLUtils.mm" \
    -o "$TEST_BUILD_DIR/tagmapper_tests"

echo "==> Compiling unit tests (YtDlpParser)..."
clang++ "${CXXFLAGS[@]}" \
    "$PROJECT_DIR/Tests/YtDlpParserTests.mm" \
    "$PROJECT_DIR/src/Core/YtDlpParser.mm" \
    "$PROJECT_DIR/src/Core/URLUtils.mm" \
    -o "$TEST_BUILD_DIR/ytdlp_parser_tests"

echo "==> Compiling unit tests (MixcloudParser)..."
clang++ "${CXXFLAGS[@]}" \
    "$PROJECT_DIR/Tests/MixcloudParserTests.mm" \
    "$PROJECT_DIR/src/Core/MixcloudParser.mm" \
    -o "$TEST_BUILD_DIR/mixcloud_parser_tests"

echo "==> Running unit tests..."
"$TEST_BUILD_DIR/url_tests"
"$TEST_BUILD_DIR/cue_tests"
"$TEST_BUILD_DIR/tagmapper_tests"
"$TEST_BUILD_DIR/ytdlp_parser_tests"
"$TEST_BUILD_DIR/mixcloud_parser_tests"

echo "==> All unit tests passed."
