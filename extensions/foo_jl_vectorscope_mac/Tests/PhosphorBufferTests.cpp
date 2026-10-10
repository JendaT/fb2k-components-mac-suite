//
//  PhosphorBufferTests.cpp
//  foo_jl_vectorscope_mac
//
//  Unit tests for the afterglow intensity buffer and its colour table.
//

#include "TestHarness.h"
#include "../src/Core/PhosphorBuffer.h"

#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

namespace {

double total(const PhosphorBuffer& b) {
    double sum = 0.0;
    for (float v : b.pixels()) sum += v;
    return sum;
}

float brightest(const PhosphorBuffer& b) {
    float m = 0.0f;
    for (float v : b.pixels()) if (v > m) m = v;
    return m;
}

// Intensity-weighted centre of the image, in pixels (row 0 = top).
void centroid(const PhosphorBuffer& b, double& cx, double& cy) {
    double sum = 0.0, sx = 0.0, sy = 0.0;
    const int side = b.side();
    for (int y = 0; y < side; ++y) {
        for (int x = 0; x < side; ++x) {
            const double v = b.pixels()[(size_t)y * side + x];
            sum += v; sx += v * x; sy += v * y;
        }
    }
    cx = sum > 0 ? sx / sum : -1;
    cy = sum > 0 ? sy / sum : -1;
}

void testGeometry() {
    g_context = "geometry";
    PhosphorBuffer b;
    b.resize(101);
    CHECK_EQ(b.side(), 101, "side");
    CHECK_EQ(b.pixels().size(), 101 * 101, "pixel count");
    CHECK_FLOAT_EQ(total(b), 0.0, "starts empty");

    const float centre[] = { 0.0f, 0.0f };
    b.addTrace(centre, 1, 1.0f, false);
    CHECK_FLOAT_EQ(total(b), 1.0, "a dot deposits exactly its energy");
    double cx, cy;
    centroid(b, cx, cy);
    CHECK_FLOAT_EQ(cx, 50.0, "origin maps to the centre column");
    CHECK_FLOAT_EQ(cy, 50.0, "origin maps to the centre row");

    b.clear();
    const float up[] = { 0.0f, 0.8f };
    b.addTrace(up, 1, 1.0f, false);
    centroid(b, cx, cy);
    CHECK_FLOAT_EQ(cy, 10.0, "positive y is towards the top (row 0)");

    b.clear();
    const float right[] = { 0.8f, 0.0f };
    b.addTrace(right, 1, 1.0f, false);
    centroid(b, cx, cy);
    CHECK_FLOAT_EQ(cx, 90.0, "positive x is towards the right");
}

void testLines() {
    g_context = "lines";
    PhosphorBuffer b;
    b.resize(201);

    const float shortSeg[] = { -0.05f, 0.0f,   0.05f, 0.0f };
    b.addTrace(shortSeg, 2, 1.0f, true);
    CHECK_FLOAT_EQ(total(b), 2.0, "a connected segment conserves energy");
    const float shortPeak = brightest(b);

    b.clear();
    const float longSeg[] = { -0.9f, 0.0f,   0.9f, 0.0f };
    b.addTrace(longSeg, 1, 1.0f, true);
    b.decay(0.0f);                       // drop the start dot, keep the stroke position
    b.addTrace(longSeg + 2, 1, 1.0f, true);
    CHECK_FLOAT_EQ(total(b), 1.0, "a long segment conserves energy");
    CHECK(brightest(b) < shortPeak * 0.2f, "fast beam movement draws dimmer");

    // The line is continuous: every column between the endpoints is lit.
    bool gap = false;
    for (int x = 12; x < 189; ++x) {
        float col = 0.0f;
        for (int y = 0; y < 201; ++y) col += b.pixels()[(size_t)y * 201 + x];
        if (col <= 0.0f) gap = true;
    }
    CHECK(!gap, "a connected segment has no gaps");

    // The stroke continues across calls until it is broken.
    b.clear();
    b.addTrace(longSeg, 1, 1.0f, true);
    b.breakTrace();
    b.addTrace(longSeg + 2, 1, 1.0f, true);
    float mid = 0.0f;
    for (int y = 0; y < 201; ++y) mid += b.pixels()[(size_t)y * 201 + 100];
    CHECK_FLOAT_EQ(mid, 0.0, "breakTrace starts a new stroke");

    // Dots mode never connects.
    b.clear();
    b.addTrace(longSeg, 2, 1.0f, false);
    mid = 0.0f;
    for (int y = 0; y < 201; ++y) mid += b.pixels()[(size_t)y * 201 + 100];
    CHECK_FLOAT_EQ(mid, 0.0, "dots are not connected");
    CHECK_FLOAT_EQ(total(b), 2.0, "dots conserve energy");
}

void testBadInput() {
    g_context = "bad input";
    PhosphorBuffer b;
    b.resize(64);
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();
    const float pts[] = {
        5.0f, 5.0f,     -5.0f, 0.0f,    nan, 0.0f,    0.0f, inf,
        1e30f, -1e30f,  1.0f, 1.0f,     -1.0f, -1.0f,
    };
    b.addTrace(pts, 7, 1.0f, true);
    b.addTrace(pts, 7, 1.0f, false);
    bool finite = true;
    for (float v : b.pixels()) if (!std::isfinite(v)) finite = false;
    CHECK(finite, "out-of-range and non-finite points leave the buffer finite");

    b.clear();
    const float far[] = { 3.0f, 3.0f };
    b.addTrace(far, 1, 1.0f, false);
    CHECK_FLOAT_EQ(total(b), 0.0, "points outside the buffer are dropped");

    const float ok[] = { 0.0f, 0.0f };
    b.addTrace(ok, 1, 0.0f, false);
    b.addTrace(ok, 1, -1.0f, false);
    b.addTrace(ok, 1, nan, false);
    CHECK_FLOAT_EQ(total(b), 0.0, "non-positive energy deposits nothing");

    PhosphorBuffer tiny;
    tiny.resize(0);
    CHECK_EQ(tiny.side(), 2, "size is clamped to a usable minimum");
    tiny.addTrace(ok, 1, 1.0f, true);

    PhosphorBuffer unsized;
    unsized.addTrace(ok, 1, 1.0f, true);
    CHECK_FLOAT_EQ(unsized.decay(0.5f), 0.0, "an unsized buffer is inert");
}

void testDecay() {
    g_context = "decay";
    PhosphorBuffer b;
    b.resize(33);
    const float centre[] = { 0.0f, 0.0f };
    b.addTrace(centre, 1, 8.0f, false);
    const float before = brightest(b);

    const float peak = b.decay(0.5f);
    CHECK_FLOAT_EQ(peak, before * 0.5f, "decay returns the brightest remaining pixel");
    CHECK_FLOAT_EQ(brightest(b), before * 0.5f, "decay scales the image");

    float last = peak;
    int frames = 0;
    while (last > 0.0f && frames < 1000) { last = b.decay(0.9f); ++frames; }
    CHECK(frames < 1000, "the image dies away completely");
    CHECK_FLOAT_EQ(total(b), 0.0, "a dead image is exactly empty");

    b.addTrace(centre, 1, 8.0f, false);
    CHECK_FLOAT_EQ(b.decay(0.0f), 0.0, "keep 0 clears");
    b.addTrace(centre, 1, 8.0f, false);
    const float held = brightest(b);
    b.decay(5.0f);
    CHECK_FLOAT_EQ(brightest(b), held, "keep above 1 never brightens");
    CHECK_FLOAT_EQ(b.decay(std::numeric_limits<float>::quiet_NaN()), 0.0, "NaN keep clears");

    // Resizing to the same side keeps the image; a new side clears it.
    b.addTrace(centre, 1, 8.0f, false);
    b.resize(33);
    CHECK(total(b) > 0.0, "same-size resize keeps the image");
    b.resize(40);
    CHECK_FLOAT_EQ(total(b), 0.0, "a new size starts empty");
}

void testRender() {
    g_context = "render";
    uint32_t lut[256];
    buildPhosphorLUT(0xFF33FF66, true, lut);

    uint8_t first[4], last[4], mid[4];
    std::memcpy(first, &lut[0], 4);
    std::memcpy(mid, &lut[128], 4);
    std::memcpy(last, &lut[255], 4);
    CHECK_EQ(first[3], 0, "zero intensity is fully transparent");
    CHECK_EQ(first[0] + first[1] + first[2], 0, "zero intensity has no colour");
    CHECK_EQ(last[3], 255, "full intensity is opaque");
    CHECK_EQ(mid[3], 128, "alpha follows intensity");
    CHECK(mid[1] > mid[0] && mid[1] > mid[2], "mid intensity keeps the trace hue (green)");
    CHECK(last[0] > 0x33 + 60, "the hot core bleaches towards white");

    bool premultiplied = true, monotone = true;
    int prevAlpha = -1;
    for (int i = 0; i < 256; ++i) {
        uint8_t px[4];
        std::memcpy(px, &lut[i], 4);
        if (px[0] > px[3] || px[1] > px[3] || px[2] > px[3]) premultiplied = false;
        if ((int)px[3] < prevAlpha) monotone = false;
        prevAlpha = px[3];
    }
    CHECK(premultiplied, "colour never exceeds alpha (premultiplied)");
    CHECK(monotone, "alpha rises with intensity");

    uint32_t flat[256];
    buildPhosphorLUT(0xFF33FF66, false, flat);
    std::memcpy(last, &flat[255], 4);
    CHECK_EQ(last[0], 0x33, "without a hot core the peak keeps the exact colour (R)");
    CHECK_EQ(last[1], 0xFF, "without a hot core the peak keeps the exact colour (G)");
    CHECK_EQ(last[2], 0x66, "without a hot core the peak keeps the exact colour (B)");

    uint32_t faded[256];
    buildPhosphorLUT(0x8033FF66, false, faded);
    std::memcpy(last, &faded[255], 4);
    CHECK_EQ(last[3], 128, "the colour's own alpha scales the trace");

    // Rendering: empty pixels take entry 0, saturated ones entry 255, and
    // row 0 of the output is the top of the scope.
    PhosphorBuffer b;
    b.resize(9);
    const float top[] = { 0.0f, 0.75f };
    b.addTrace(top, 1, 1e6f, false);
    std::vector<uint8_t> rgba(9 * 9 * 4, 0xAB);
    b.render(rgba.data(), lut);
    CHECK_EQ(std::memcmp(&rgba[(size_t)(1 * 9 + 4) * 4], &lut[255], 4), 0, "a saturated pixel takes the last entry");
    CHECK_EQ(std::memcmp(&rgba[(size_t)(8 * 9 + 4) * 4], &lut[0], 4), 0, "an empty pixel takes the first entry");
    CHECK_EQ(std::memcmp(&rgba[0], &lut[0], 4), 0, "every pixel is written");
}

} // namespace

int main() {
    testGeometry();
    testLines();
    testBadInput();
    testDecay();
    testRender();
    TEST_MAIN_END();
}
