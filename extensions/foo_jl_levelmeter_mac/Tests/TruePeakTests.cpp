//
//  TruePeakTests.cpp
//  foo_jl_levelmeter_mac
//
//  Inter-sample peak detection.
//

#include "TestHarness.h"
#include "../src/Core/TruePeak.h"

#include <cmath>
#include <vector>

using namespace meter;

namespace {

const double kPi = 3.14159265358979323846;

std::vector<float> sine(double hz, double sr, double seconds, double amp, double phase) {
    std::vector<float> v((size_t)(seconds * sr));
    for (size_t i = 0; i < v.size(); ++i) v[i] = (float)(amp * std::sin(2.0 * kPi * hz * (double)i / sr + phase));
    return v;
}

float samplePeak(const std::vector<float> &v) {
    float p = 0;
    for (float x : v) p = std::max(p, std::fabs(x));
    return p;
}

double db(double v) { return 20.0 * std::log10(v); }

void testTable() {
    g_context = "table";
    // Phase 0 is a pure delay: one unit tap, the rest zero.
    int ones = 0;
    for (int j = 0; j < TruePeakDetector::kTapsPerPhase; ++j) {
        const float c = TruePeakDetector::coeff(0, j);
        if (std::fabs(c - 1.0f) < 1e-6f) ++ones;
        else CHECK(std::fabs(c) < 1e-6f, "phase 0 off-centre taps are zero");
    }
    CHECK_EQ(ones, 1, "phase 0 has one unit tap");
    for (int p = 0; p < TruePeakDetector::kFactor; ++p) {
        double sum = 0;
        for (int j = 0; j < TruePeakDetector::kTapsPerPhase; ++j) sum += TruePeakDetector::coeff(p, j);
        CHECK(std::fabs(sum - 1.0) < 1e-5, "unity DC gain per phase");
    }
}

void testInterSamplePeak() {
    g_context = "fs/4 at 45 degrees";
    // Every sample lands at +-0.707 of a full-scale sine: the sample peak
    // reads -3 dB but the waveform reaches 0 dB between samples.
    const double sr = 48000.0;
    auto v = sine(sr / 4.0, sr, 0.1, 1.0, kPi / 4.0);
    CHECK(std::fabs(db(samplePeak(v)) + 3.01) < 0.05, "sample peak is -3 dB");
    TruePeakDetector tp;
    const float peak = tp.process(v.data(), v.size(), 1);
    CHECK(std::fabs(db(peak)) < 0.3, "true peak near 0 dB");
}

void testSineLevels() {
    const double sr = 44100.0;
    for (double hz : { 100.0, 997.0, 5000.0, 12000.0 }) {
        g_context = "sine " + std::to_string((int)hz);
        auto v = sine(hz, sr, 0.2, 0.5, 0.3);
        TruePeakDetector tp;
        const float peak = tp.process(v.data(), v.size(), 1);
        CHECK(peak >= samplePeak(v) - 1e-6f, "never below the sample peak");
        CHECK(std::fabs(db(peak) - db(0.5)) < 0.25, "reads the sine's peak");
    }
}

void testStrideAndReset() {
    g_context = "stride";
    // Interleaved: left loud, right quiet.
    std::vector<float> lr(2000);
    for (size_t i = 0; i < 1000; ++i) {
        lr[2 * i] = (float)(0.8 * std::sin(0.05 * (double)i));
        lr[2 * i + 1] = (float)(0.1 * std::sin(0.05 * (double)i));
    }
    TruePeakDetector l, r;
    CHECK(std::fabs(l.process(lr.data(), 1000, 2) - 0.8f) < 0.01f, "left channel");
    CHECK(std::fabs(r.process(lr.data() + 1, 1000, 2) - 0.1f) < 0.01f, "right channel");

    g_context = "reset";
    TruePeakDetector tp;
    float one = 1.0f;
    tp.process(&one, 1, 1);
    tp.reset();
    std::vector<float> zeros(64, 0.0f);
    CHECK_FLOAT_EQ(tp.process(zeros.data(), zeros.size(), 1), 0.0, "history cleared");

    g_context = "dc";
    std::vector<float> dc(256, 0.25f);
    TruePeakDetector d;
    d.process(dc.data(), 64, 1);   // let the filter fill
    CHECK(std::fabs(d.process(dc.data(), dc.size(), 1) - 0.25f) < 1e-4f, "constant reads flat");
}

} // namespace

int main() {
    testTable();
    testInterSamplePeak();
    testSineLevels();
    testStrideAndReset();
    TEST_MAIN_END();
}
