//
//  LayeredShapeTests.cpp
//  foo_jl_wave_seekbar_mac
//
//  Unit tests for the Layered style's dBFS geometry. Standalone.
//
// TEST_DEPS: src/Core/ColumnAggregator.cpp src/Core/TrackAnalyzer.cpp src/Core/WaveformData.cpp
// TEST_LIBS: -lz
//

#include "TestHarness.h"
#include "../src/Core/LayeredShape.h"
#include "../src/Core/TrackAnalyzer.h"

#include <cmath>
#include <vector>

namespace {

void testFraction() {
    g_context = "fraction";
    CHECK_FLOAT_EQ(layered::fraction(0.0f), 1.0, "0 dBFS fills the half");
    CHECK_FLOAT_EQ(layered::fraction(-18.0f), 0.5, "-18 dB is half way to the -36 floor");
    CHECK_FLOAT_EQ(layered::fraction(-36.0f), 0.0, "floor");
    CHECK_FLOAT_EQ(layered::fraction(-60.0f), 0.0, "below the floor");
    CHECK_FLOAT_EQ(layered::fraction(3.0f), 1.0, "over 0 dBFS clamps");
    CHECK_FLOAT_EQ(layered::fraction(-INFINITY), 0.0, "silence");
    CHECK_FLOAT_EQ(layered::fraction(NAN), 0.0, "undefined");
    CHECK_FLOAT_EQ(layered::fraction(-12.0f, -24.0f), 0.5, "other floors");
}

void testShape() {
    // L at -6 dBFS, R at -18 dBFS, 997 Hz: peaks and bodies per half
    const double sr = 48000.0, kPi = 3.14159265358979323846;
    std::vector<float> lr;
    for (size_t i = 0; i < (size_t)(sr * 6); ++i) {
        const float s = (float)std::sin(2.0 * kPi * 997.0 * i / sr);
        lr.push_back(0.5012f * s);
        lr.push_back(0.1259f * s);
    }
    analysis::TrackAnalyzer a((uint32_t)sr, 2, lr.size() / 2);
    a.process(lr.data(), lr.size() / 2, 2);
    const analysis::Columns cols = analysis::aggregateColumns(a.finish(), 40);
    const layered::Shape s = layered::shapeFor(cols);

    g_context = "shape";
    CHECK_EQ(s.peak[0].size(), 40, "columns");
    CHECK(std::fabs(s.peak[0][20] - (36.0f - 6.0f) / 36.0f) < 0.01f, "L peak at -6 dBFS");
    CHECK(std::fabs(s.peak[1][20] - (36.0f - 18.0f) / 36.0f) < 0.01f, "R peak at -18 dBFS");
    // A sine's RMS sits 3 dB under its peak
    CHECK(std::fabs(s.body[0][20] - (36.0f - 9.0f) / 36.0f) < 0.02f, "L body 3 dB under the peak");
    CHECK(s.body[0][20] <= s.peak[0][20] && s.body[1][20] <= s.peak[1][20], "body inside the peaks");

    g_context = "mono";
    analysis::TrackAnalyzer m((uint32_t)sr, 1, 48000);
    std::vector<float> mono(48000, 0.25f);
    m.process(mono.data(), mono.size(), 1);
    const layered::Shape ms = layered::shapeFor(analysis::aggregateColumns(m.finish(), 10));
    CHECK_FLOAT_EQ(ms.peak[0][5], ms.peak[1][5], "mono fills both halves alike");
}

} // namespace

int main() {
    testFraction();
    testShape();
    TEST_MAIN_END();
}
