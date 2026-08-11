//
//  WaveformGeometryTests.cpp
//  foo_wave_seekbar_mac
//

#include "TestSupport.h"
#include "../src/Core/WaveformGeometry.h"

using namespace waveseek;

namespace {

void testChannelLayouts() {
    TEST_CASE("channel layouts");

    ChannelLayout left = stereoLeftLayout(100.0);
    ChannelLayout right = stereoRightLayout(100.0);

    CHECK_NEAR(left.centerY, 75.0, 1e-9, "left channel centres in the upper half");
    CHECK_NEAR(right.centerY, 25.0, 1e-9, "right channel centres in the lower half");
    CHECK_NEAR(left.amplitude, 21.0, 1e-9, "stereo amplitude is a quarter height less padding");
    CHECK_NEAR(right.amplitude, left.amplitude, 1e-9, "both stereo channels share an amplitude");

    // The halves must not overlap: each reaches at most `amplitude` from its
    // centre, and they are half the view height apart.
    CHECK(left.centerY - left.amplitude > right.centerY + right.amplitude,
          "stereo channels do not overlap");

    ChannelLayout mono = monoLayout(100.0);
    CHECK_NEAR(mono.centerY, 50.0, 1e-9, "mono centres in the middle");
    CHECK_NEAR(mono.amplitude, 46.0, 1e-9, "mono amplitude is half height less padding");

    // A view too short for the padding yields a negative amplitude; callers
    // draw nothing rather than inverting, so just pin the behaviour.
    ChannelLayout tiny = monoLayout(4.0);
    CHECK(tiny.amplitude <= 0.0, "a view shorter than the padding has no amplitude");
}

void testBucketMapping() {
    TEST_CASE("bucket mapping");

    CHECK_NEAR(bucketX(0, 2048, 512.0), 0.0, 1e-9, "first bucket sits at the left edge");
    CHECK_NEAR(bucketX(1024, 2048, 512.0), 256.0, 1e-9, "middle bucket sits at half width");
    CHECK_NEAR(bucketX(2047, 2048, 512.0), 511.75, 1e-9, "last bucket sits just inside the right edge");
    CHECK_NEAR(bucketX(5, 0, 512.0), 0.0, 1e-9, "zero buckets degrade to the left edge");

    CHECK_NEAR(bucketPosition(0, 2048), 0.0, 1e-9, "first bucket is at track start");
    CHECK_NEAR(bucketPosition(512, 2048), 0.25, 1e-9, "quarter-way bucket reports a quarter");
    CHECK_NEAR(bucketPosition(3, 0), 0.0, 1e-9, "zero buckets degrade to track start");
}

void testPeakAmplitude() {
    TEST_CASE("peak amplitude");

    CHECK_NEAR(peakAmplitude(-0.8, 0.3), 0.8, 1e-9, "negative excursion can dominate");
    CHECK_NEAR(peakAmplitude(-0.2, 0.6), 0.6, 1e-9, "positive excursion can dominate");
    CHECK_NEAR(peakAmplitude(0.0, 0.0), 0.0, 1e-9, "silence has no deflection");
    CHECK_NEAR(peakAmplitude(-1.0, 1.0), 1.0, 1e-9, "full scale reads as full scale");
}

void testMonoDownmix() {
    TEST_CASE("mono downmix");

    // Channels in phase: both strategies agree.
    MinMax envInPhase = monoDownmixEnvelope(-0.5, 0.5, -0.5, 0.5);
    MinMax avgInPhase = monoDownmixAverage(-0.5, 0.5, -0.5, 0.5);
    CHECK_NEAR(envInPhase.max, 0.5, 1e-9, "envelope of matched channels is the channel");
    CHECK_NEAR(avgInPhase.max, 0.5, 1e-9, "average of matched channels is the channel");

    // Wide stereo: this is where they diverge, which is why both exist.
    MinMax envWide = monoDownmixEnvelope(-0.9, 0.9, -0.1, 0.1);
    MinMax avgWide = monoDownmixAverage(-0.9, 0.9, -0.1, 0.1);
    CHECK_NEAR(envWide.max, 0.9, 1e-9, "envelope keeps the louder channel");
    CHECK_NEAR(envWide.min, -0.9, 1e-9, "envelope keeps the deeper trough");
    CHECK_NEAR(avgWide.max, 0.5, 1e-9, "average splits the difference");
    CHECK(avgWide.max < envWide.max, "average reads lower than envelope on wide stereo");
}

void testGradientBands() {
    TEST_CASE("gradient bands");

    BandRange first = bandRange(0, 4);
    BandRange last = bandRange(3, 4);
    CHECK_NEAR(first.start, 0.0, 1e-9, "first band starts at the baseline");
    CHECK_NEAR(first.end, 0.25, 1e-9, "first band ends a quarter out");
    CHECK_NEAR(last.end, 1.0, 1e-9, "last band reaches full scale");

    // Bands must tile without gaps.
    CHECK_NEAR(bandRange(1, 4).start, bandRange(0, 4).end, 1e-9, "bands tile contiguously");

    CHECK_NEAR(bandAlpha(0, 4), 1.0, 1e-9, "the baseline band is fully opaque");
    CHECK_NEAR(bandAlpha(3, 4), 0.55, 1e-9, "the outermost band is faded");
    CHECK(bandAlpha(3, 4) < bandAlpha(0, 4), "alpha decreases away from the baseline");

    // A zero band count would divide by zero; it must degrade instead.
    BandRange degenerate = bandRange(0, 0);
    CHECK_NEAR(degenerate.end, 1.0, 1e-9, "zero bands degrade to a single full-scale band");

    CHECK(clampGradientBands(8) == 8, "an in-range band count passes through");
    CHECK(clampGradientBands(64) == 32, "an excessive band count is clamped");
    CHECK(clampGradientBands(0) == 0, "zero bands stays zero (flat trace)");
}

void testCursorFade() {
    TEST_CASE("cursor fade width");

    CHECK_NEAR(cursorFadeWidth(200.0), 4.0, 1e-9, "narrow views scale the fade");
    CHECK_NEAR(cursorFadeWidth(2000.0), 10.0, 1e-9, "wide views cap the fade");
    CHECK_NEAR(cursorFadeWidth(0.0), 0.0, 1e-9, "a zero-width view has no fade");
}

void testSeekConversion() {
    TEST_CASE("seek conversion");

    CHECK_NEAR(normalizedPositionForX(100.0, 400.0), 0.25, 1e-9, "x maps to a track fraction");
    CHECK_NEAR(normalizedPositionForX(-50.0, 400.0), 0.0, 1e-9, "dragging left of the view pins to the start");
    CHECK_NEAR(normalizedPositionForX(9999.0, 400.0), 1.0, 1e-9, "dragging right of the view pins to the end");
    CHECK_NEAR(normalizedPositionForX(10.0, 0.0), 0.0, 1e-9, "a zero-width view cannot seek");

    CHECK_NEAR(seekTimeForPosition(0.25, 200.0), 50.0, 1e-9, "position scales to seconds");
    CHECK_NEAR(seekTimeForPosition(0.0, 200.0), 0.0, 1e-9, "start of track is time zero");
}

void testAccessibilityNudge() {
    TEST_CASE("accessibility nudge");

    CHECK_NEAR(nudgedPosition(0.5, 100.0, 5.0), 0.55, 1e-9, "increment moves forward by five seconds");
    CHECK_NEAR(nudgedPosition(0.5, 100.0, -5.0), 0.45, 1e-9, "decrement moves back by five seconds");
    CHECK_NEAR(nudgedPosition(0.98, 100.0, 5.0), 1.0, 1e-9, "increment clamps at the end");
    CHECK_NEAR(nudgedPosition(0.01, 100.0, -5.0), 0.0, 1e-9, "decrement clamps at the start");
    CHECK_NEAR(nudgedPosition(0.4, 0.0, 5.0), 0.4, 1e-9, "no duration means no movement");
}

void testRedrawThreshold() {
    TEST_CASE("redraw threshold");

    // A quarter pixel of cursor travel, expressed as track fraction.
    CHECK_NEAR(positionRedrawThreshold(400.0), 0.000625, 1e-12, "threshold is a quarter pixel");
    CHECK(positionRedrawThreshold(1600.0) < positionRedrawThreshold(400.0),
          "wider views need finer position changes to repaint");
    CHECK_NEAR(positionRedrawThreshold(0.0), 0.001, 1e-12, "a collapsed view uses the fallback");
    CHECK_NEAR(positionRedrawThreshold(1.0), 0.001, 1e-12, "a one-pixel view uses the fallback");
}

} // namespace

int main() {
    testChannelLayouts();
    testBucketMapping();
    testPeakAmplitude();
    testMonoDownmix();
    testGradientBands();
    testCursorFade();
    testSeekConversion();
    testAccessibilityNudge();
    testRedrawThreshold();
    return testsupport::summarize("WaveformGeometryTests");
}
