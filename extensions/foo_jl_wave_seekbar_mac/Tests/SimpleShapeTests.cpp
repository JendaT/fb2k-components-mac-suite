//
//  SimpleShapeTests.cpp
//  foo_jl_wave_seekbar_mac
//
//  Unit tests for the Simple styles' lane geometry. Standalone.
//
// TEST_DEPS: src/Core/ColumnAggregator.cpp src/Core/TrackAnalyzer.cpp src/Core/WaveformData.cpp
// TEST_LIBS: -lz
//

#include "TestHarness.h"
#include "../src/Core/SimpleShape.h"
#include "../src/Core/TrackAnalyzer.h"

#include <cmath>
#include <vector>

namespace {

simple::Shape shapeOf(const std::vector<float>& lr, uint32_t channels, size_t columns) {
    analysis::TrackAnalyzer a(48000, channels, lr.size() / channels);
    a.process(lr.data(), lr.size() / channels, channels);
    return simple::shapeFor(analysis::aggregateColumns(a.finish(), columns));
}

void testSine() {
    // L sine at 0.5, R sine at 0.25: linear heights, core meets the peaks
    g_context = "sine";
    const double kPi = 3.14159265358979323846;
    std::vector<float> lr;
    for (size_t i = 0; i < 48000 * 4; ++i) {
        const float s = (float)std::sin(2.0 * kPi * 440.0 * i / 48000.0);
        lr.push_back(0.5f * s);
        lr.push_back(0.25f * s);
    }
    const simple::Shape s = shapeOf(lr, 2, 32);
    CHECK(std::fabs(s.lane[0].top[16] - 0.5f) < 0.01f, "L top");
    CHECK(std::fabs(s.lane[0].bottom[16] + 0.5f) < 0.01f, "L bottom");
    CHECK(std::fabs(s.lane[1].top[16] - 0.25f) < 0.01f, "R top, linear");
    CHECK(std::fabs(s.lane[0].coreTop[16] - 0.5f) < 0.01f, "RMS x sqrt 2 of a sine is its peak");
    CHECK(s.lane[0].coreTop[16] <= s.lane[0].top[16] && s.lane[0].coreBottom[16] >= s.lane[0].bottom[16],
          "core inside the peaks");
}

void testAsymmetricAndMono() {
    // DC offset: the peak layer follows min and max separately
    g_context = "asymmetric";
    std::vector<float> lr;
    for (size_t i = 0; i < 48000; ++i) {
        const float v = (i % 2) ? 0.6f : -0.2f;
        lr.push_back(v);
        lr.push_back(v);
    }
    const simple::Shape s = shapeOf(lr, 2, 8);
    CHECK(std::fabs(s.lane[0].top[4] - 0.6f) < 0.01f, "top follows the maximum");
    CHECK(std::fabs(s.lane[0].bottom[4] + 0.2f) < 0.01f, "bottom follows the minimum");
    CHECK(s.lane[0].coreBottom[4] >= s.lane[0].bottom[4] - 1e-6f, "core clamped to the minimum");

    g_context = "mono";
    std::vector<float> mono(48000, 0.3f);
    const simple::Shape m = shapeOf(mono, 1, 8);
    CHECK_FLOAT_EQ(m.lane[0].top[4], m.lane[1].top[4], "mono fills both lanes alike");

    g_context = "one lane";
    const simple::Shape one = simple::shapeFor(analysis::mixdown(analysis::aggregateColumns(
        [] { analysis::TrackAnalyzer a(48000, 2, 48000); std::vector<float> v(2 * 48000, 0.0f);
             for (size_t i = 0; i < v.size(); i += 2) v[i] = 0.4f;
             a.process(v.data(), 48000, 2); return a.finish(); }(), 8)), 1);
    CHECK_EQ(one.lanes, 1, "lane count");
    CHECK(std::fabs(one.lane[0].top[4] - 0.4f) < 0.01f, "the mix keeps the louder channel's peaks");
    CHECK(one.lane[1].top.empty(), "no second lane");

    g_context = "silence";
    const simple::Shape z = shapeOf(std::vector<float>(2 * 48000, 0.0f), 2, 8);
    CHECK_FLOAT_EQ(z.lane[0].top[4], 0.0, "flat");
    CHECK_FLOAT_EQ(z.lane[1].coreBottom[4], 0.0, "no core");
}

} // namespace

int main() {
    testSine();
    testAsymmetricAndMono();
    TEST_MAIN_END();
}
