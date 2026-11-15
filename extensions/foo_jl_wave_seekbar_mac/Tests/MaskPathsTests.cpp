//
//  MaskPathsTests.cpp
//  foo_wave_seekbar_mac
//
//  The mask shapes, filled a run of columns at a time, against the exact
//  pixel coverage of the outline they stand for: no seams where runs meet
//  or along a lane's centre line, and the ends as the whole-path outline.
//
// TEST_LIBS: -framework CoreGraphics
//

#include "TestSupport.h"
#include "../src/Core/MaskPaths.h"

#include <cmath>
#include <cstdint>
#include <random>

using namespace waveseek::masks;

namespace {

const size_t kHeight = 81;          // odd: lane centres fall mid-pixel
const double kTolerance = 3.0;      // /255; runs measured within 1.3

struct Mask {
    size_t width = 0, height = 0;
    std::vector<uint8_t> px;        // row 0 at the top, as CoreGraphics stores it
    uint8_t at(size_t x, size_t yFromBottom) const { return px[(height - 1 - yFromBottom) * width + x]; }
};

// Renders as the view does: black, then white through the path
template <typename Draw>
Mask render(size_t width, size_t height, Draw draw) {
    Mask m;
    m.width = width;
    m.height = height;
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, width, height, 8, 0, gray, kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!ctx) return m;
    CGContextSetGrayFillColor(ctx, 0.0, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    draw(ctx);
    const uint8_t* data = (const uint8_t*)CGBitmapContextGetData(ctx);
    const size_t stride = CGBitmapContextGetBytesPerRow(ctx);
    for (size_t r = 0; r < height; ++r) m.px.insert(m.px.end(), data + r * stride, data + r * stride + width);
    CGContextRelease(ctx);
    return m;
}

// The whole-track outline: straight between column centres, level from the
// edges to the first and last centres
double outline(const std::vector<float>& v, double x) {
    const size_t n = v.size();
    if (x <= 0.5) return v[0];
    if (x >= n - 0.5) return v[n - 1];
    const size_t c = (size_t)(x - 0.5);
    const double t = x - 0.5 - c;
    return v[c] + (v[c + 1] - v[c]) * t;
}

// Exact coverage (0..255) of the pixel (x, y) by the region between y = lo(x)
// and y = hi(x): exact vertically, 256 samples across
template <typename Lo, typename Hi>
double coverage(size_t x, size_t y, Lo lo, Hi hi) {
    const int kSamples = 256;
    double sum = 0.0;
    for (int s = 0; s < kSamples; ++s) {
        const double px = x + (s + 0.5) / kSamples;
        const double a = std::max<double>(y, lo(px)), b = std::min<double>(y + 1.0, hi(px));
        sum += std::max(0.0, b - a);
    }
    return sum / kSamples * 255.0;
}

std::vector<float> jagged(size_t n, unsigned seed, float lo, float hi) {
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> u(lo, hi);
    std::vector<float> v(n);
    for (auto& x : v) x = u(rng);
    return v;
}

void testHeightAt() {
    TEST_CASE("heightAt");

    const std::vector<float> v = { 0.2f, 0.6f, 1.0f };
    CHECK_NEAR(heightAt(v, 0), 0.2, 1e-6, "level with the first centre at the left edge");
    CHECK_NEAR(heightAt(v, 1), 0.4, 1e-6, "halfway between centres");
    CHECK_NEAR(heightAt(v, 2), 0.8, 1e-6, "halfway, further on");
    CHECK_NEAR(heightAt(v, 3), 1.0, 1e-6, "level with the last centre at the right edge");
    CHECK_NEAR(heightAt({}, 0), 0.0, 1e-6, "no columns");
}

// Layered: both halves of a lane, as the view adds them, against the exact
// area between the centre line and the outline
void testHalvesMatchOutline() {
    TEST_CASE("half shapes");

    for (size_t width : { (size_t)7, (size_t)70, (size_t)301 }) {
        const std::vector<float> up = jagged(width, 1 + (unsigned)width, 0.0f, 1.0f);
        const std::vector<float> down = jagged(width, 2 + (unsigned)width, 0.0f, 1.0f);
        const double centre = kHeight / 2.0, amplitude = kHeight / 2.0 - 2.0;
        const Mask m = render(width, kHeight, [&](CGContextRef ctx) {
            fillInRuns(ctx, width, [&](size_t c0, size_t c1) {
                addHalfShape(ctx, up, c0, c1, centre, amplitude, 1.0);
                addHalfShape(ctx, down, c0, c1, centre, amplitude, -1.0);
            });
        });
        CHECK(m.px.size() == width * kHeight, "rendered");
        if (m.px.size() != width * kHeight) continue;

        double worst = 0.0, worstCentre = 0.0;
        for (size_t x = 0; x < width; ++x) {
            for (size_t y = 0; y < kHeight; ++y) {
                const double exact = coverage(x, y,
                    [&](double px) { return centre - outline(down, px) * amplitude; },
                    [&](double px) { return centre + outline(up, px) * amplitude; });
                const double err = std::fabs(m.at(x, y) - exact);
                worst = std::max(worst, err);
                if (y == kHeight / 2) worstCentre = std::max(worstCentre, err);
            }
        }
        CHECK(worst <= kTolerance, "within the tolerance of the exact coverage everywhere");
        CHECK(worstCentre <= kTolerance, "no seam along the centre line");
        if (worst > kTolerance) std::printf("    width %zu: max error %.1f/255\n", width, worst);
    }
}

// Simple: bands between a top and a bottom outline
void testBandsMatchOutline() {
    TEST_CASE("bands");

    const size_t width = 150;
    const std::vector<float> top = jagged(width, 7, 0.05f, 1.0f);
    const std::vector<float> bottom = jagged(width, 8, -1.0f, -0.05f);
    const double centre = kHeight / 2.0, amplitude = kHeight / 2.0 - 1.0;
    const Mask m = render(width, kHeight, [&](CGContextRef ctx) {
        fillInRuns(ctx, width, [&](size_t c0, size_t c1) {
            addBand(ctx, top, bottom, c0, c1, centre, amplitude);
        });
    });
    CHECK(m.px.size() == width * kHeight, "rendered");
    if (m.px.size() != width * kHeight) return;

    double worst = 0.0;
    for (size_t x = 0; x < width; ++x) {
        for (size_t y = 0; y < kHeight; ++y) {
            const double exact = coverage(x, y,
                [&](double px) { return centre + outline(bottom, px) * amplitude; },
                [&](double px) { return centre + outline(top, px) * amplitude; });
            worst = std::max(worst, std::fabs(m.at(x, y) - exact));
        }
    }
    CHECK(worst <= kTolerance, "within the tolerance of the exact coverage");
    if (worst > kTolerance) std::printf("    max error %.1f/255\n", worst);
}

// A level outline across several runs draws identical columns: nothing
// marks where one run ends and the next begins
void testNoSeamsBetweenRuns() {
    TEST_CASE("run boundaries");

    const size_t width = kFillChunk * 4 + 5;
    const std::vector<float> level(width, 0.637f);
    const Mask m = render(width, kHeight, [&](CGContextRef ctx) {
        fillInRuns(ctx, width, [&](size_t c0, size_t c1) {
            addHalfShape(ctx, level, c0, c1, kHeight / 2.0, kHeight / 2.0 - 2.0, 1.0);
            addHalfShape(ctx, level, c0, c1, kHeight / 2.0, kHeight / 2.0 - 2.0, -1.0);
        });
    });
    CHECK(m.px.size() == width * kHeight, "rendered");
    if (m.px.size() != width * kHeight) return;

    bool same = true;
    for (size_t x = 1; x < width; ++x) {
        for (size_t y = 0; y < kHeight; ++y) same = same && m.at(x, y) == m.at(0, y);
    }
    CHECK(same, "every column matches the first");
}

} // namespace

int main() {
    testHeightAt();
    testHalvesMatchOutline();
    testBandsMatchOutline();
    testNoSeamsBetweenRuns();
    return testsupport::summarize("MaskPathsTests");
}
