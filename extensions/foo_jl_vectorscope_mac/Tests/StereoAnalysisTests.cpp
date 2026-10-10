//
//  StereoAnalysisTests.cpp
//  foo_jl_vectorscope_mac
//
//  Unit tests for the stereo-field maths (goniometer mapping, correlation,
//  band splitting, auto-gain). Standalone: no SDK, no Xcode.
//

#include "TestHarness.h"
#include "../src/Core/StereoAnalysis.h"

#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

using namespace stereo;

namespace {

const double kSR = 48000.0;
const double kPi = 3.14159265358979323846;

// Interleaved stereo sine: L at phase 0, R scaled by `rGain` and shifted.
std::vector<float> sinePair(double hz, double seconds, float rGain, double rPhase = 0.0) {
    const size_t n = (size_t)(seconds * kSR);
    std::vector<float> lr(n * 2);
    for (size_t i = 0; i < n; ++i) {
        const double ph = 2.0 * kPi * hz * (double)i / kSR;
        lr[2 * i]     = (float)(0.5 * std::sin(ph));
        lr[2 * i + 1] = (float)(0.5 * rGain * std::sin(ph + rPhase));
    }
    return lr;
}

// Seeded LCG so noise-based tests are reproducible.
struct Rng {
    uint32_t s;
    float next() {
        s = s * 1664525u + 1013904223u;
        return (float)(s >> 8) / 8388608.0f - 1.0f;   // -1..1
    }
};

double rmsOfChannel(const std::vector<float>& lr, int ch, size_t skipFrames) {
    double sum = 0.0;
    size_t n = 0;
    for (size_t i = skipFrames; i < lr.size() / 2; ++i, ++n) {
        sum += (double)lr[2 * i + ch] * lr[2 * i + ch];
    }
    return n ? std::sqrt(sum / (double)n) : 0.0;
}

float correlationOf(const std::vector<float>& lr, double integration = 0.3) {
    CorrelationMeter m;
    m.configure(kSR, integration);
    m.process(lr.data(), lr.size() / 2);
    return m.value();
}

void testGoniometer() {
    g_context = "goniometer";
    const float lr[] = { 1, 1,   1, 0,   0, 1,   1, -1,   0, 0 };
    float xy[10];
    goniometerPoints(lr, 5, 1.0f, xy);
    CHECK_FLOAT_EQ(xy[0], 0.0, "mono x");
    CHECK_FLOAT_EQ(xy[1], 1.0, "mono y (top)");
    CHECK_FLOAT_EQ(xy[2], -0.5, "left-only x (leans left)");
    CHECK_FLOAT_EQ(xy[3], 0.5, "left-only y");
    CHECK_FLOAT_EQ(xy[4], 0.5, "right-only x (leans right)");
    CHECK_FLOAT_EQ(xy[5], 0.5, "right-only y");
    CHECK_FLOAT_EQ(xy[6], -1.0, "out-of-phase x (horizontal)");
    CHECK_FLOAT_EQ(xy[7], 0.0, "out-of-phase y");
    CHECK_FLOAT_EQ(xy[8], 0.0, "silence x");
    CHECK_FLOAT_EQ(xy[9], 0.0, "silence y");

    goniometerPoints(lr, 1, 0.5f, xy);
    CHECK_FLOAT_EQ(xy[1], 0.5, "gain scales the point");

    // Full-scale input never leaves the diamond at gain 1.
    Rng rng{12345};
    bool inside = true;
    for (int i = 0; i < 2000; ++i) {
        const float in[2] = { rng.next(), rng.next() };
        float out[2];
        goniometerPoints(in, 1, 1.0f, out);
        if (std::fabs(out[0]) + std::fabs(out[1]) > 1.0001f) inside = false;
    }
    CHECK(inside, "full-scale input stays inside the diamond");

    const float pk[] = { 0.1f, -0.7f, 0.3f, 0.2f };
    CHECK_FLOAT_EQ(blockPeak(pk, 2), 0.7, "blockPeak takes the absolute maximum");
}

void testCorrelation() {
    g_context = "correlation";
    CHECK_FLOAT_EQ(correlationOf(sinePair(440, 2.0, 1.0f)), 1.0, "identical channels");
    CHECK_FLOAT_EQ(correlationOf(sinePair(440, 2.0, 0.25f)), 1.0, "same signal at different levels");
    CHECK_FLOAT_EQ(correlationOf(sinePair(440, 2.0, -1.0f)), -1.0, "inverted channel");
    CHECK(std::fabs(correlationOf(sinePair(440, 2.0, 1.0f, kPi / 2))) < 0.02, "90 degree shift reads 0");
    CHECK_FLOAT_EQ(correlationOf(sinePair(440, 2.0, 0.0f)), 0.0, "one-sided signal reads 0");

    // Unrelated noise in each channel.
    Rng rng{777};
    std::vector<float> noise((size_t)kSR * 2 * 2);
    for (float& v : noise) v = 0.5f * rng.next();
    CHECK(std::fabs(correlationOf(noise, 0.5)) < 0.1, "independent noise reads near 0");

    // Silence.
    std::vector<float> quiet((size_t)kSR * 2, 0.0f);
    CorrelationMeter m;
    m.configure(kSR, 0.3);
    m.process(quiet.data(), quiet.size() / 2);
    CHECK(m.silent(), "digital silence is silent");
    CHECK_FLOAT_EQ(m.value(), 0.0, "silence reads 0");

    // Readings hold, then drop out, once the audio stops.
    auto tone = sinePair(440, 2.0, 1.0f);
    m.process(tone.data(), tone.size() / 2);
    CHECK(!m.silent(), "tone is not silent");
    m.idle(0.05);
    CHECK_FLOAT_EQ(m.value(), 1.0, "reading holds through a short gap");
    m.idle(10.0);
    CHECK(m.silent(), "long gap decays to silent");
    CHECK_FLOAT_EQ(m.value(), 0.0, "silent reads 0");

    // Integration time: flipping from in-phase to out-of-phase, the reading
    // follows -1 + 2 * exp(-t / tau).
    const double tau = 0.5;
    CorrelationMeter step;
    step.configure(kSR, tau);
    auto inPhase = sinePair(1000, 5.0, 1.0f);
    auto outPhase = sinePair(1000, tau, -1.0f);
    step.process(inPhase.data(), inPhase.size() / 2);
    step.process(outPhase.data(), outPhase.size() / 2);
    CHECK(std::fabs(step.value() - (-1.0 + 2.0 * std::exp(-1.0))) < 0.03, "one time constant after a flip");

    // A non-finite sample must not stick.
    CorrelationMeter bad;
    bad.configure(kSR, 0.3);
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float poison[] = { nan, 0.5f };
    bad.process(poison, 1);
    bad.process(tone.data(), tone.size() / 2);
    CHECK_FLOAT_EQ(bad.value(), 1.0, "meter recovers after a NaN sample");
}

void testSplitter() {
    g_context = "splitter";
    const struct { double hz; int band; } cases[] = { {60, 0}, {800, 1}, {8000, 2} };
    for (const auto& c : cases) {
        ThreeBandSplitter sp;
        sp.configure(kSR, 250.0, 2000.0);
        auto in = sinePair(c.hz, 1.0, 1.0f);
        const size_t frames = in.size() / 2;
        std::vector<float> out[3] = { std::vector<float>(in.size()), std::vector<float>(in.size()),
                                      std::vector<float>(in.size()) };
        sp.process(in.data(), frames, out[0].data(), out[1].data(), out[2].data());
        const size_t skip = frames / 2;   // let the filters settle
        const double ref = rmsOfChannel(in, 0, skip);
        for (int b = 0; b < 3; ++b) {
            const double ratio = rmsOfChannel(out[b], 0, skip) / ref;
            if (b == c.band) CHECK(ratio > 0.9 && ratio < 1.1, "tone passes its own band");
            else             CHECK(ratio < 0.05, "tone is rejected by the other bands");
        }
        // Both channels are filtered identically.
        CHECK_FLOAT_EQ(rmsOfChannel(out[c.band], 0, skip), rmsOfChannel(out[c.band], 1, skip),
                       "channels match");
    }

    // Crossovers above Nyquist are clamped instead of going unstable.
    ThreeBandSplitter wild;
    wild.configure(8000.0, 250.0, 20000.0);
    auto in = sinePair(440, 0.5, 1.0f);
    std::vector<float> a(in.size()), b(in.size()), c(in.size());
    wild.process(in.data(), in.size() / 2, a.data(), b.data(), c.data());
    bool finite = true;
    for (size_t i = 0; i < in.size(); ++i) {
        if (!std::isfinite(a[i]) || !std::isfinite(b[i]) || !std::isfinite(c[i])) finite = false;
    }
    CHECK(finite, "out-of-range crossover stays finite");
}

void testAutoGain() {
    g_context = "autogain";
    AutoGain ag;
    ag.configure(0.9f, 0.5f, 31.6f, 3.0);
    const double block = 1.0 / 60.0;

    for (int i = 0; i < 600; ++i) ag.process(0.09f, block);
    CHECK(std::fabs(ag.gain() - 10.0f) < 0.1f, "quiet material is raised to the target");

    // Silence holds the gain instead of running it up to the maximum.
    for (int i = 0; i < 600; ++i) ag.process(0.0f, block);
    CHECK(std::fabs(ag.gain() - 10.0f) < 0.1f, "silence holds the gain");

    // A loud passage pulls the gain down within a fraction of a second.
    for (int i = 0; i < 60; ++i) ag.process(1.0f, block);
    CHECK(std::fabs(ag.gain() - 0.9f) < 0.05f, "loud material is brought back to the target");

    // Release is slow: one second later the gain has barely recovered.
    for (int i = 0; i < 60; ++i) ag.process(0.09f, block);
    CHECK(ag.gain() < 2.0f, "gain recovers slowly after a loud passage");

    // Very quiet material is capped at the maximum gain.
    AutoGain cap;
    cap.configure(0.9f, 0.5f, 31.6f, 3.0);
    for (int i = 0; i < 600; ++i) cap.process(0.001f, block);
    CHECK(std::fabs(cap.gain() - 31.6f) < 0.1f, "gain is capped");
}

void testAnalyzer() {
    g_context = "analyzer";
    // 60 Hz in phase plus 8 kHz out of phase, at equal level.
    const size_t frames = (size_t)(kSR * 3.0);
    std::vector<float> lr(frames * 2);
    for (size_t i = 0; i < frames; ++i) {
        const double lo = 0.3 * std::sin(2.0 * kPi * 60.0 * (double)i / kSR);
        const double hi = 0.3 * std::sin(2.0 * kPi * 8000.0 * (double)i / kSR);
        lr[2 * i]     = (float)(lo + hi);
        lr[2 * i + 1] = (float)(lo - hi);
    }

    StereoAnalyzer::Settings s;
    s.multiband = true;
    s.autoGain = false;
    s.manualGain = 2.0f;
    StereoAnalyzer an;
    an.configure(s);

    // Feed in display-frame sized blocks, as the controller does.
    std::vector<float> xy(1600);
    const size_t block = 800;
    for (size_t off = 0; off + block <= frames; off += block) {
        an.process(lr.data() + off * 2, block, kSR, xy.data());
    }
    CHECK(an.bandCorrelation(StereoAnalyzer::BandLow) > 0.95f, "low band reads in phase");
    CHECK(an.bandCorrelation(StereoAnalyzer::BandHigh) < -0.95f, "high band reads out of phase");
    CHECK(std::fabs(an.correlation()) < 0.1f, "broadband reading hides the conflict");
    CHECK_FLOAT_EQ(an.gain(), 2.0, "manual gain is reported");

    // The points written are the goniometer mapping of the last block.
    const float* last = lr.data() + (frames - block) * 2;
    CHECK_FLOAT_EQ(xy[0], (last[1] - last[0]) * 0.5f * 2.0f, "point x uses the gain");
    CHECK_FLOAT_EQ(xy[1], (last[0] + last[1]) * 0.5f * 2.0f, "point y uses the gain");

    an.idle(20.0);
    CHECK(an.silent(), "idle decays the broadband meter");
    CHECK(an.bandSilent(StereoAnalyzer::BandLow), "idle decays the band meters");

    // With multiband off the band meters are not fed.
    StereoAnalyzer::Settings wideOnly;
    StereoAnalyzer plain;
    plain.configure(wideOnly);
    for (size_t off = 0; off + block <= frames; off += block) {
        plain.process(lr.data() + off * 2, block, kSR, xy.data());
    }
    CHECK(!plain.silent(), "broadband meter runs with multiband off");
    CHECK(plain.bandSilent(StereoAnalyzer::BandLow), "band meters stay idle with multiband off");
    CHECK(plain.gain() > 1.0f, "auto gain raises a -7 dBFS signal");

    // A sample-rate change mid-stream is absorbed.
    an.process(lr.data(), block, 96000.0, xy.data());
    CHECK(std::isfinite(an.correlation()), "sample-rate change keeps readings finite");
}

} // namespace

int main() {
    testGoniometer();
    testCorrelation();
    testSplitter();
    testAutoGain();
    testAnalyzer();
    TEST_MAIN_END();
}
