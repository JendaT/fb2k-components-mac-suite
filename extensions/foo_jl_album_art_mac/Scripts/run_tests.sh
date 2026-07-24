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

# Sources shared by the provider and controller test binaries
CORE_SOURCES=(
    "$PROJECT_DIR/src/Core/ArtworkResult.mm"
    "$PROJECT_DIR/src/Core/TrackMetadata.mm"
    "$PROJECT_DIR/src/Core/ArtworkSourceProvider.mm"
    "$PROJECT_DIR/src/Core/iTunesProvider.mm"
    "$PROJECT_DIR/src/Core/DeezerProvider.mm"
    "$PROJECT_DIR/src/Core/CoverArtArchiveProvider.mm"
    "$PROJECT_DIR/src/Core/MusicBrainzProvider.mm"
    "$PROJECT_DIR/src/Core/TidalProvider.mm"
    "$SHARED_DIR/RateLimiter.mm"
    "$SHARED_DIR/NetworkReachability.mm"
)

echo "==> Compiling unit tests (TrackMetadata)..."
clang++ $CXXFLAGS \
    "$PROJECT_DIR/Tests/TrackMetadataTests.mm" \
    "$PROJECT_DIR/src/Core/TrackMetadata.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/trackmetadata_tests"

echo "==> Compiling unit tests (ArtworkResult)..."
clang++ $CXXFLAGS \
    "$PROJECT_DIR/Tests/ArtworkResultTests.mm" \
    "$PROJECT_DIR/src/Core/ArtworkResult.mm" \
    -framework Foundation -framework CoreGraphics \
    -o "$TEST_BUILD_DIR/artworkresult_tests"

echo "==> Compiling unit tests (Provider parsing)..."
clang++ $CXXFLAGS \
    "$PROJECT_DIR/Tests/ProviderParsingTests.mm" \
    "${CORE_SOURCES[@]}" \
    $FRAMEWORKS \
    -o "$TEST_BUILD_DIR/providerparsing_tests"

echo "==> Compiling unit tests (RemoteArtworkSearchController)..."
clang++ $CXXFLAGS \
    "$PROJECT_DIR/Tests/RemoteArtworkSearchControllerTests.mm" \
    "$PROJECT_DIR/src/Core/RemoteArtworkSearchController.mm" \
    "${CORE_SOURCES[@]}" \
    $FRAMEWORKS \
    -o "$TEST_BUILD_DIR/searchcontroller_tests"

echo "==> Running unit tests..."
"$TEST_BUILD_DIR/trackmetadata_tests"
"$TEST_BUILD_DIR/artworkresult_tests"
"$TEST_BUILD_DIR/providerparsing_tests"
"$TEST_BUILD_DIR/searchcontroller_tests"

echo "==> All unit tests passed"
