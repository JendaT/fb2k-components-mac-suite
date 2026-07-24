#!/bin/bash
#
# run_tests.sh - Compile and run unit tests for the pure-logic Core code.
#
# The code under test is Foundation-only (no foobar2000 SDK), so it compiles
# standalone with clang in a few seconds - no Xcode target or SDK needed.
# Invoked as a gating phase by build.sh; exits non-zero on any failure.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="$(cd "$PROJECT_DIR/../../shared" && pwd)"
TEST_BUILD_DIR="$PROJECT_DIR/build/tests"

mkdir -p "$TEST_BUILD_DIR"

CXXFLAGS="-x objective-c++ -std=gnu++17 -fobjc-arc -O1 -Wall"
FRAMEWORKS="-framework Foundation -framework CoreGraphics -framework Network"

# Core sources are globbed so a new file is covered without editing this
# script, matching generate_xcode_project.rb. Files that pull in the
# foobar2000 SDK or AppKit cannot compile standalone and are excluded.
SDK_DEPENDENT_SOURCES=(
    "AlbumArtFetcher.mm"
    "ArtworkEmbedController.mm"
    "ArtworkSaveController.mm"
    "TrackMetadataFB2K.mm"
)

CORE_SOURCES=()
for src in "$PROJECT_DIR"/src/Core/*.mm; do
    base="$(basename "$src")"
    excluded=0
    for skipped in "${SDK_DEPENDENT_SOURCES[@]}"; do
        if [ "$base" = "$skipped" ]; then
            excluded=1
            break
        fi
    done
    if [ $excluded -eq 0 ]; then
        CORE_SOURCES+=("$src")
    fi
done
CORE_SOURCES+=(
    "$SHARED_DIR/RateLimiter.mm"
    "$SHARED_DIR/NetworkReachability.mm"
)

# Every Tests/*.mm file is its own binary with its own main()
TEST_BINARIES=()
for test_src in "$PROJECT_DIR"/Tests/*.mm; do
    test_name="$(basename "$test_src" .mm)"
    test_binary="$TEST_BUILD_DIR/$(echo "$test_name" | tr '[:upper:]' '[:lower:]')"

    echo "==> Compiling unit tests ($test_name)..."
    clang++ $CXXFLAGS \
        "$test_src" \
        "${CORE_SOURCES[@]}" \
        $FRAMEWORKS \
        -o "$test_binary"

    TEST_BINARIES+=("$test_binary")
done

echo "==> Running unit tests..."
for test_binary in "${TEST_BINARIES[@]}"; do
    "$test_binary"
done

echo "==> All unit tests passed"
