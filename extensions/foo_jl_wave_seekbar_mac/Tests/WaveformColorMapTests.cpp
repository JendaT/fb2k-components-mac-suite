//
//  WaveformColorMapTests.cpp
//  foo_wave_seekbar_mac
//

#include "TestSupport.h"
#include "../src/Core/WaveformColorMap.h"

using namespace waveseek;

namespace {

void checkRgb(const Rgb& actual, double r, double g, double b, const char* what) {
    CHECK_NEAR(actual.r, r, 1e-6, what);
    CHECK_NEAR(actual.g, g, 1e-6, what);
    CHECK_NEAR(actual.b, b, 1e-6, what);
}

void testHeatMapStops() {
    TEST_CASE("heat map stops");

    checkRgb(heatMapColor(0.0), 0.0, 0.0, 1.0, "silence is blue");
    checkRgb(heatMapColor(0.25), 0.0, 1.0, 1.0, "quarter scale is cyan");
    checkRgb(heatMapColor(0.5), 0.0, 1.0, 0.0, "half scale is green");
    checkRgb(heatMapColor(0.75), 1.0, 1.0, 0.0, "three-quarter scale is yellow");
    checkRgb(heatMapColor(1.0), 1.0, 0.0, 0.0, "full scale is red");
}

void testHeatMapClamping() {
    TEST_CASE("heat map clamping");

    // Amplitudes outside 0..1 must pin to the ends rather than wrap or
    // produce out-of-gamut components.
    checkRgb(heatMapColor(-5.0), 0.0, 0.0, 1.0, "below zero clamps to blue");
    checkRgb(heatMapColor(5.0), 1.0, 0.0, 0.0, "above one clamps to red");

    // Every component must stay in gamut across the whole ramp.
    for (int i = 0; i <= 100; i++) {
        Rgb c = heatMapColor(i / 100.0);
        bool inGamut = c.r >= 0.0 && c.r <= 1.0 && c.g >= 0.0 && c.g <= 1.0 &&
                       c.b >= 0.0 && c.b <= 1.0;
        CHECK(inGamut, "heat map stays in gamut across the ramp");
    }
}

void testRainbowStops() {
    TEST_CASE("rainbow stops");

    checkRgb(rainbowColor(0.0), 1.0, 0.0, 0.0, "hue zero is red");
    checkRgb(rainbowColor(1.0 / 3.0), 0.0, 1.0, 0.0, "a third round is green");
    checkRgb(rainbowColor(2.0 / 3.0), 0.0, 0.0, 1.0, "two thirds round is blue");

    // The ramp is cyclic: a full turn returns to the start.
    checkRgb(rainbowColor(1.0), 1.0, 0.0, 0.0, "a full turn wraps back to red");
    checkRgb(rainbowColor(2.5), rainbowColor(0.5).r, rainbowColor(0.5).g, rainbowColor(0.5).b,
             "positions beyond one wrap");
    checkRgb(rainbowColor(-0.5), rainbowColor(0.5).r, rainbowColor(0.5).g, rainbowColor(0.5).b,
             "negative positions wrap forward");

    for (int i = 0; i <= 100; i++) {
        Rgb c = rainbowColor(i / 100.0);
        bool inGamut = c.r >= 0.0 && c.r <= 1.0 && c.g >= 0.0 && c.g <= 1.0 &&
                       c.b >= 0.0 && c.b <= 1.0;
        CHECK(inGamut, "rainbow stays in gamut across the ramp");
        // Full saturation and value: one component is always at each extreme.
        double maxC = std::max(c.r, std::max(c.g, c.b));
        CHECK_NEAR(maxC, 1.0, 1e-6, "rainbow keeps full value");
    }
}

void testArgbConversion() {
    TEST_CASE("ARGB conversion");

    Rgba opaqueBlue = rgbaFromArgb(0xFF3380CC);
    CHECK_NEAR(opaqueBlue.a, 1.0, 1e-6, "alpha byte unpacks to full opacity");
    CHECK_NEAR(opaqueBlue.r, 0x33 / 255.0, 1e-6, "red byte unpacks");
    CHECK_NEAR(opaqueBlue.g, 0x80 / 255.0, 1e-6, "green byte unpacks");
    CHECK_NEAR(opaqueBlue.b, 0xCC / 255.0, 1e-6, "blue byte unpacks");

    Rgba transparent = rgbaFromArgb(0x00000000);
    CHECK_NEAR(transparent.a, 0.0, 1e-6, "zero alpha unpacks to transparent");
}

void testArgbRoundTrip() {
    TEST_CASE("ARGB round trip");

    // Saving and reloading preferences must not drift a colour. Every byte
    // value has to survive the trip through doubles intact.
    for (uint32_t v = 0; v < 256; v++) {
        uint32_t packed = (0xFFu << 24) | (v << 16) | (v << 8) | v;
        uint32_t roundTripped = argbFromRgba(rgbaFromArgb(packed));
        CHECK(roundTripped == packed, "every grey level round-trips exactly");
    }

    uint32_t colors[] = {0xFF3380CC, 0xFFF2F2F2, 0xFF4D99E6, 0xFF1A1A1A, 0x80112233, 0x00FFFFFF};
    for (uint32_t c : colors) {
        CHECK(argbFromRgba(rgbaFromArgb(c)) == c, "default and partial-alpha colours round-trip");
    }
}

void testArgbClamping() {
    TEST_CASE("ARGB clamping");

    // Out-of-range components (an NSColor from a wide-gamut space) must not
    // wrap around into an unrelated colour.
    uint32_t clamped = argbFromRgba({2.0, -1.0, 0.5, 1.0});
    CHECK(((clamped >> 16) & 0xFF) == 0xFF, "over-bright red clamps to full");
    CHECK(((clamped >> 8) & 0xFF) == 0x00, "negative green clamps to zero");
    CHECK((clamped >> 24) == 0xFF, "alpha packs into the top byte");
}

void testAnimationFrequency() {
    TEST_CASE("animation frequency");

    CHECK_NEAR(animationFrequency(true, 120.0, 1.0), 2.0, 1e-9, "120 BPM drives 2Hz");
    CHECK_NEAR(animationFrequency(true, 60.0, 1.0), 1.0, 1e-9, "60 BPM drives 1Hz");

    // Without sync, or without a known tempo, the effect keeps its own rate.
    CHECK_NEAR(animationFrequency(false, 120.0, 2.5), 2.5, 1e-9, "sync off keeps the default rate");
    CHECK_NEAR(animationFrequency(true, 0.0, 2.5), 2.5, 1e-9, "unknown tempo keeps the default rate");
    CHECK_NEAR(animationFrequency(true, -30.0, 1.5), 1.5, 1e-9, "a nonsense tempo keeps the default rate");
}

void testOscillator() {
    TEST_CASE("oscillator");

    // Effects scale this into alphas and widths, so it must stay inside 0..1.
    for (int i = 0; i <= 200; i++) {
        double v = oscillator(i * 0.05, 1.7);
        CHECK(v >= -1e-9 && v <= 1.0 + 1e-9, "oscillator stays within 0..1");
    }

    CHECK_NEAR(oscillator(0.0, 1.0), 0.5, 1e-9, "phase zero sits mid-swing");
    CHECK_NEAR(oscillator(0.25, 1.0), 1.0, 1e-9, "a quarter period reaches the peak");
    CHECK_NEAR(oscillator(0.75, 1.0), 0.0, 1e-9, "three quarters reaches the trough");

    // A full period returns to the start.
    CHECK_NEAR(oscillator(1.0, 1.0), oscillator(0.0, 1.0), 1e-9, "one period is cyclic");
    CHECK_NEAR(oscillator(0.0, 1.0, M_PI / 2.0), 1.0, 1e-9, "phase offset shifts the swing");
}

} // namespace

int main() {
    testHeatMapStops();
    testHeatMapClamping();
    testRainbowStops();
    testArgbConversion();
    testArgbRoundTrip();
    testArgbClamping();
    testAnimationFrequency();
    testOscillator();
    return testsupport::summarize("WaveformColorMapTests");
}
