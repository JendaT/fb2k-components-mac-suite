//
//  OverlayTextTests.cpp
//  foo_jl_wave_seekbar_mac
//
//  Unit tests for overlay number / time formatting and readout placement.
//

#include "TestHarness.h"
#include "../src/Core/OverlayText.h"

#include <cmath>
#include <string>

using namespace waveseek::overlay;

namespace {

#define CHECK_STR(actual, expected, what)                                        \
    do {                                                                         \
        g_checks++;                                                             \
        const std::string chk_a = (actual), chk_e = (expected);                 \
        if (chk_a != chk_e) {                                                   \
            g_failures++;                                                       \
            printf("FAIL %s:%d [%s] %s: got \"%s\", expected \"%s\"\n",         \
                   __FILE__, __LINE__, g_context.c_str(), what,                 \
                   chk_a.c_str(), chk_e.c_str());                               \
        }                                                                       \
    } while (0)

void testNumbers() {
    g_context = "numbers";
    CHECK_STR(formatNumber(-12.44, 1), "−12.4", "Unicode minus");
    CHECK_STR(formatNumber(0.4, 1, true), "+0.4", "explicit plus");
    CHECK_STR(formatNumber(0.4, 1), "0.4", "no plus by default");
    CHECK_STR(formatNumber(-0.04, 1), "0.0", "rounds to zero without a sign");
    CHECK_STR(formatNumber(0.724, 2, true), "+0.72", "two decimals");
    CHECK_STR(formatNumber(-INFINITY, 1), "−∞", "minus infinity");
    CHECK_STR(formatNumber(NAN, 1), "—", "undefined");
}

void testClock() {
    g_context = "clock";
    CHECK_STR(formatClock(0), "0:00", "zero");
    CHECK_STR(formatClock(241.7), "4:01", "m:ss truncates");
    CHECK_STR(formatClock(612.66, true), "10:12.6", "tenths");
    CHECK_STR(formatClock(5.31, true), "0:05.3", "leading zero");
    CHECK_STR(formatClock(59.96, true), "0:59.9", "tenths truncate");
    CHECK_STR(formatClock(3725, false), "1:02:05", "hours");
    CHECK_STR(formatClock(3725.25, true), "1:02:05.2", "hours with tenths");
    CHECK_STR(formatClock(-3), "0:00", "negative clamps");
}

void testPlacement() {
    g_context = "placement";
    CHECK_FLOAT_EQ(readoutX(100, 1000), 110, "right of the mouse");
    CHECK_FLOAT_EQ(readoutX(800, 1000), 604, "flips within 210 pt of the right edge");
    CHECK_FLOAT_EQ(readoutX(789, 1000), 799, "still right just outside the zone");
    CHECK_FLOAT_EQ(readoutX(150, 300), 0, "never off the left edge");
    CHECK_FLOAT_EQ(readoutX(700, 1000, 279), 411, "a larger box flips earlier");
    CHECK_FLOAT_EQ(readoutX(690, 1000, 279), 700, "and stays right outside its zone");
}

void testRuler() {
    g_context = "ruler";
    // The handoff's mock: 21:18 over 1392 pt gives labels every 2 min
    CHECK_FLOAT_EQ(rulerInterval(1278, 1392), 120, "2 min on the mock");
    CHECK_FLOAT_EQ(rulerInterval(180, 1200), 30, "3 min track, wide view");
    CHECK_FLOAT_EQ(rulerInterval(60, 2000), 10, "short track: the smallest step");
    CHECK_FLOAT_EQ(rulerInterval(7200, 800), 1800, "2 h mix in 800 pt");
    CHECK_FLOAT_EQ(rulerInterval(36000, 800), 7200, "10 h in 800 pt: whole hours past the list");
    CHECK_FLOAT_EQ(rulerInterval(86400, 100), 97200, "a day in 100 pt still keeps the labels apart");
    CHECK_FLOAT_EQ(rulerInterval(0, 1000), 10, "no duration");
    const double interval = rulerInterval(425, 1915);
    CHECK(interval * 1915 / 425 >= kRulerLabelSpacing, "labels at least 110 pt apart");
}

} // namespace

int main() {
    testNumbers();
    testClock();
    testPlacement();
    testRuler();
    TEST_MAIN_END();
}
