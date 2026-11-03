//
//  ZoomRangeTests.cpp
//  foo_wave_seekbar_mac
//

#include "TestSupport.h"
#include "../src/Core/ZoomRange.h"

#include <limits>

using namespace waveseek;

namespace {

void testDefault() {
    TEST_CASE("default");

    ZoomRange z;
    CHECK(!z.zoomed(), "starts unzoomed");
    CHECK_NEAR(z.start, 0.0, 1e-12, "at the track start");
    CHECK_NEAR(z.end(), 1.0, 1e-12, "showing the whole track");
    CHECK_NEAR(z.positionAt(0.25), 0.25, 1e-12, "position is the fraction across");
    CHECK_NEAR(z.acrossOf(0.75), 0.75, 1e-12, "and back");
}

void testZoomKeepsAnchor() {
    TEST_CASE("zoom about a point");

    ZoomRange z;
    z.zoomBy(4.0, 0.5, 100.0);
    CHECK_NEAR(z.zoom, 4.0, 1e-12, "zoomed by the factor");
    CHECK_NEAR(z.start, 0.375, 1e-12, "centred on the middle");
    CHECK_NEAR(z.end(), 0.625, 1e-12, "a quarter of the track");

    // The track position under the pointer stays under it
    const double before = z.positionAt(0.3);
    z.zoomBy(2.5, 0.3, 100.0);
    CHECK_NEAR(z.positionAt(0.3), before, 1e-12, "the anchor stays put");
    CHECK_NEAR(z.zoom, 10.0, 1e-12, "factors multiply");

    // Round trip between a point across and a position
    CHECK_NEAR(z.acrossOf(z.positionAt(0.8)), 0.8, 1e-12, "positionAt and acrossOf invert");
    CHECK(z.acrossOf(0.0) < 0.0, "positions before the range map left of the waveform");
    CHECK(z.acrossOf(1.0) > 1.0, "positions after it map right of it");
}

void testZoomAtEdges() {
    TEST_CASE("zoom at the edges");

    ZoomRange z;
    z.zoomBy(8.0, 0.0, 100.0);
    CHECK_NEAR(z.start, 0.0, 1e-12, "zooming at the left edge keeps the track start");

    z.reset();
    z.zoomBy(8.0, 1.0, 100.0);
    CHECK_NEAR(z.end(), 1.0, 1e-12, "zooming at the right edge keeps the track end");

    // An anchor outside the waveform (the level gutter) clamps to its edge
    z.reset();
    z.zoomBy(8.0, 1.7, 100.0);
    CHECK_NEAR(z.end(), 1.0, 1e-12, "an anchor past the right edge clamps");
}

void testLimits() {
    TEST_CASE("zoom limits");

    ZoomRange z;
    z.zoomBy(1000.0, 0.5, 16.0);
    CHECK_NEAR(z.zoom, 16.0, 1e-12, "stops at the maximum");

    z.zoomBy(1.0 / 1000.0, 0.5, 16.0);
    CHECK_NEAR(z.zoom, 1.0, 1e-12, "zooming out stops at the whole track");
    CHECK(!z.zoomed(), "and is no longer zoomed");
    CHECK_NEAR(z.start, 0.0, 1e-12, "showing it from the start");

    z.zoomBy(4.0, 0.5, 0.5);
    CHECK_NEAR(z.zoom, 1.0, 1e-12, "a maximum under 1 allows no zoom");

    // The view got narrower: zooming in further keeps the zoom, zooming out works
    z.reset();
    z.zoomBy(32.0, 0.5, 32.0);
    z.zoomBy(2.0, 0.5, 8.0);
    CHECK_NEAR(z.zoom, 32.0, 1e-12, "past the maximum, zooming in changes nothing");
    z.zoomBy(0.5, 0.5, 8.0);
    CHECK_NEAR(z.zoom, 16.0, 1e-12, "zooming out still works");

    const ZoomRange before = z;
    z.zoomBy(0.0, 0.5, 64.0);
    z.zoomBy(-2.0, 0.5, 64.0);
    z.zoomBy(std::numeric_limits<double>::quiet_NaN(), 0.5, 64.0);
    z.zoomBy(std::numeric_limits<double>::infinity(), 0.5, 64.0);
    CHECK(z == before, "zero, negative, NaN and infinite factors are ignored");
}

void testPan() {
    TEST_CASE("pan");

    ZoomRange z;
    z.panBy(0.5);
    CHECK_NEAR(z.start, 0.0, 1e-12, "the whole track can't pan");

    z.zoomBy(4.0, 0.0, 100.0);
    z.panBy(1.0);
    CHECK_NEAR(z.start, 0.25, 1e-12, "a full width moves by the visible span");
    z.panBy(-0.5);
    CHECK_NEAR(z.start, 0.125, 1e-12, "negative goes earlier");

    z.panBy(100.0);
    CHECK_NEAR(z.end(), 1.0, 1e-12, "stops at the track end");
    z.panBy(-100.0);
    CHECK_NEAR(z.start, 0.0, 1e-12, "stops at the track start");

    const ZoomRange before = z;
    z.panBy(std::numeric_limits<double>::quiet_NaN());
    CHECK(z == before, "NaN is ignored");
}

void testMaxZoom() {
    TEST_CASE("max zoom");

    // 4 points per block: 10 000 blocks in 800 pt allow 50x
    CHECK_NEAR(maxZoomFor(10000, 800.0), 50.0, 1e-12, "four points per block");
    CHECK_NEAR(maxZoomFor(100, 800.0), 1.0, 1e-12, "a short track never zooms below the whole track");
    CHECK_NEAR(maxZoomFor(0, 800.0), 1.0, 1e-12, "no blocks");
    CHECK_NEAR(maxZoomFor(10000, 0.0), 1.0, 1e-12, "no width");
}

} // namespace

int main() {
    testDefault();
    testZoomKeepsAnchor();
    testZoomAtEdges();
    testLimits();
    testPan();
    testMaxZoom();
    return testsupport::summarize("ZoomRangeTests");
}
