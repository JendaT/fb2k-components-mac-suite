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

echo "==> Compiling unit tests (LastFmParsing)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/LastFmParsingTests.mm" \
    "$PROJECT_DIR/src/Core/LastFmParsing.mm" \
    "$PROJECT_DIR/src/Core/BiographyData.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/lastfm_parsing_tests"

echo "==> Compiling unit tests (ArtistNameMatcher)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/ArtistNameMatcherTests.mm" \
    "$PROJECT_DIR/src/Core/ArtistNameMatcher.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/name_matcher_tests"

echo "==> Compiling unit tests (GalleryImageParsing)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/GalleryImageParsingTests.mm" \
    "$PROJECT_DIR/src/Core/GalleryImageParsing.mm" \
    "$PROJECT_DIR/src/Core/ArtistImage.mm" \
    -framework Foundation -framework CoreGraphics \
    -o "$TEST_BUILD_DIR/image_parsing_tests"

echo "==> Compiling unit tests (ArtistGalleryData)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/ArtistGalleryDataTests.mm" \
    "$PROJECT_DIR/src/Core/ArtistGalleryData.mm" \
    "$PROJECT_DIR/src/Core/ArtistImage.mm" \
    -framework Foundation -framework CoreGraphics \
    -o "$TEST_BUILD_DIR/gallery_data_tests"

echo "==> Compiling unit tests (RateLimiter)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/RateLimiterTests.mm" \
    "$PROJECT_DIR/src/Core/RateLimiter.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/rate_limiter_tests"

echo "==> Compiling unit tests (GalleryFetchState)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/GalleryFetchStateTests.mm" \
    "$PROJECT_DIR/src/Core/GalleryFetchState.mm" \
    "$PROJECT_DIR/src/Core/ArtistGalleryData.mm" \
    "$PROJECT_DIR/src/Core/ArtistImage.mm" \
    -framework Foundation -framework CoreGraphics \
    -o "$TEST_BUILD_DIR/fetch_state_tests"

echo "==> Compiling unit tests (MusicBrainzParsing)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/MusicBrainzParsingTests.mm" \
    "$PROJECT_DIR/src/Core/MusicBrainzParsing.mm" \
    "$PROJECT_DIR/src/Core/ArtistNameMatcher.mm" \
    "$PROJECT_DIR/src/Core/GalleryImageParsing.mm" \
    "$PROJECT_DIR/src/Core/ArtistImage.mm" \
    -framework Foundation -framework CoreGraphics \
    -o "$TEST_BUILD_DIR/musicbrainz_parsing_tests"

echo "==> Compiling unit tests (WikipediaParsing)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/WikipediaParsingTests.mm" \
    "$PROJECT_DIR/src/Core/WikipediaParsing.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/wikipedia_parsing_tests"

echo "==> Compiling unit tests (GalleryCacheKeys)..."
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall \
    "$PROJECT_DIR/Tests/GalleryCacheKeysTests.mm" \
    "$PROJECT_DIR/src/Core/GalleryCacheKeys.mm" \
    -framework Foundation \
    -o "$TEST_BUILD_DIR/cache_keys_tests"

echo "==> Running unit tests..."
"$TEST_BUILD_DIR/lastfm_parsing_tests"
"$TEST_BUILD_DIR/name_matcher_tests"
"$TEST_BUILD_DIR/image_parsing_tests"
"$TEST_BUILD_DIR/gallery_data_tests"
"$TEST_BUILD_DIR/rate_limiter_tests"
"$TEST_BUILD_DIR/fetch_state_tests"
"$TEST_BUILD_DIR/musicbrainz_parsing_tests"
"$TEST_BUILD_DIR/wikipedia_parsing_tests"
"$TEST_BUILD_DIR/cache_keys_tests"
