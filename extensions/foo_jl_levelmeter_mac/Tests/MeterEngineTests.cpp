//
//  MeterEngineTests.cpp
//  foo_jl_levelmeter_mac
//
//  Display ballistics, maxima, clip latching and the combined snapshot.
//
// TEST_DEPS: src/Core/Detectors.cpp src/Core/Loudness.cpp src/Core/TruePeak.cpp

#include "TestHarness.h"
#include "../src/Core/MeterEngine.h"

#include <cmath>
#include <vector>

using namespace meter;

namespace {

const double kPi = 3.14159265358979323846;
const double kSR = 48000.0;
const double kFrame = 1.0 / 60.0;

// Run `seconds` of a stereo sine (peak `lAmp` / `rAmp`) in 60 Hz frames.
void run(MeterEngine &e, double seconds, double lAmp, double rAmp, double hz = 1000.0,
         double rPhase = 0.0, int channels = 2) {
    static double phase = 0.0;
    const size_t perFrame = (size_t)(kSR * kFrame);
    std::vector<float> buf(perFrame * 2);
    for (int f = 0; f < (int)std::lround(seconds / kFrame); ++f) {
        for (size_t i = 0; i < perFrame; ++i) {
            buf[2 * i] = (float)(lAmp * std::sin(phase));
            buf[2 * i + 1] = (float)(rAmp * std::sin(phase + rPhase));
            phase += 2.0 * kPi * hz / kSR;
        }
        e.process(buf.data(), perFrame, kSR, channels);
        e.advance(kFrame);
    }
}

void idleFor(MeterEngine &e, double seconds) {
    for (int f = 0; f < (int)std::lround(seconds / kFrame); ++f) {
        e.idle(kFrame);
        e.advance(kFrame);
    }
}

void testLevels() {
    g_context = "levels";
    MeterEngine e;
    EngineSettings s;
    s.truePeak = false;
    e.configure(s);
    run(e, 1.0, 0.5, 0.25);
    const Snapshot &snap = e.snapshot();
    CHECK(std::fabs(snap.ch[0].peakDb + 6.02) < 0.1, "left peak -6 dB");
    CHECK(std::fabs(snap.ch[1].peakDb + 12.04) < 0.1, "right peak -12 dB");
    CHECK(std::fabs(snap.ch[0].rmsDb + 9.03) < 0.1, "left RMS -9 dB");
    CHECK(std::fabs(snap.ch[0].maxDb + 6.02) < 0.1, "max follows peak");
    CHECK(!snap.ch[0].clip, "no clip");
    CHECK(snap.active, "active while audio arrives");
    CHECK(snap.balanceDb < -5.9 && snap.balanceDb > -6.1, "balance leans left by 6 dB");
    CHECK(snap.correlation > 0.99f, "in-phase pair correlates");

    g_context = "rms sine reads peak";
    s.rmsSineReadsPeak = true;
    e.configure(s);
    run(e, 0.5, 0.5, 0.5);
    CHECK(std::fabs(e.snapshot().ch[0].rmsDb + 6.02) < 0.1, "+3 dB RMS matches the peak");
}

void testFallAndHold() {
    g_context = "fall and hold";
    MeterEngine e;
    EngineSettings s;
    s.truePeak = false;
    s.peakFallDbPerSecond = 12.0;
    s.peakHoldSeconds = 1.0;
    e.configure(s);
    run(e, 0.5, 1.0, 1.0);
    idleFor(e, 0.5);
    const Snapshot &snap = e.snapshot();
    CHECK(std::fabs(snap.ch[0].peakDb + 6.0) < 0.3, "bar falls 12 dB/s");
    CHECK(std::fabs(snap.ch[0].holdDb) < 0.05, "hold stays during the hold time");
    CHECK(!snap.active, "inactive when idle");
    idleFor(e, 1.0);
    CHECK(snap.ch[0].holdDb < -5.0, "hold falls after the hold time");
    CHECK(snap.ch[0].holdDb >= snap.ch[0].peakDb, "hold never under the bar");
    CHECK(std::fabs(snap.ch[0].maxDb) < 0.05, "max keeps the session peak");

    g_context = "hold forever";
    s.peakHoldForever = true;
    e.configure(s);
    e.resetPeaks();
    run(e, 0.2, 0.5, 0.5);
    idleFor(e, 5.0);
    CHECK(std::fabs(e.snapshot().ch[0].holdDb + 6.02) < 0.1, "hold kept until reset");
    e.resetPeaks();
    CHECK(e.snapshot().ch[0].holdDb <= kFloorDb, "reset clears hold");
}

void testClipAndTruePeak() {
    g_context = "clip";
    MeterEngine e;
    EngineSettings s;
    s.truePeak = false;
    e.configure(s);
    run(e, 0.2, 1.2, 0.5);
    CHECK(e.snapshot().ch[0].clip, "left over 0 dBFS clips");
    CHECK(!e.snapshot().ch[1].clip, "right does not");
    idleFor(e, 2.0);
    CHECK(e.snapshot().ch[0].clip, "clip latches");
    e.resetPeaks();
    CHECK(!e.snapshot().ch[0].clip, "reset clears clip");

    g_context = "true peak over";
    // fs/4 at 45 degrees, samples at 0.99 of a waveform peaking near 1.4:
    // sample peak stays under 0 dBFS, true peak goes over.
    MeterEngine t;
    EngineSettings ts;
    ts.truePeak = true;
    t.configure(ts);
    const size_t n = 800;
    std::vector<float> buf(n * 2);
    for (size_t i = 0; i < n; ++i) {
        const float v = (float)(1.4 * std::sin(2.0 * kPi * (double)i / 4.0 + kPi / 4.0));
        buf[2 * i] = buf[2 * i + 1] = v;
    }
    t.process(buf.data(), n, kSR, 2);
    t.advance(kFrame);
    CHECK(t.snapshot().ch[0].maxDb > 2.0f, "true peak sees the inter-sample over");
    CHECK(t.snapshot().ch[0].clip, "inter-sample over lights the clip");
    CHECK(t.snapshot().truePeakMaxDb > 2.0f, "true peak max");
}

void testNeedle() {
    g_context = "needle reference";
    MeterEngine e;
    EngineSettings s;
    s.referenceDbfs = -18.0;
    e.configure(s);
    // Sine at -18 dBFS RMS reads 0 VU.
    const double amp = std::sqrt(2.0) * std::pow(10.0, -18.0 / 20.0);
    run(e, 1.5, amp, amp);
    CHECK(std::fabs(e.snapshot().ch[0].needleDb) < 0.2, "0 VU at the reference");

    g_context = "needle stop";
    run(e, 1.0, 1.0, 1.0);
    CHECK(e.snapshot().ch[0].needleDb < 3.7f, "pinned near +3.6 VU");

    g_context = "needle ppm";
    s.needle = NeedleBallistics::PpmDin;
    e.configure(s);
    run(e, 1.0, amp, amp);
    CHECK(std::fabs(e.snapshot().ch[0].needleDb) < 0.4, "PPM reads 0 at the reference sine");
    idleFor(e, 1.0);
    CHECK(e.snapshot().ch[0].needleDb < -12.0f, "PPM falls when idle");
}

void testLoudnessAndStereo() {
    g_context = "loudness";
    MeterEngine e;
    e.configure(EngineSettings());
    const double amp = std::pow(10.0, -23.0 / 20.0);
    run(e, 5.0, amp, amp);
    const Snapshot &snap = e.snapshot();
    CHECK(std::fabs(snap.momentary + 23.0) < 0.15, "momentary");
    CHECK(std::fabs(snap.integrated + 23.0) < 0.15, "integrated");
    // Stereo sine: peak -23 dBFS, loudness -23 LUFS, so peak - short-term is 0.
    CHECK(std::fabs(snap.psrDb) < 0.3, "PSR = peak - short-term");
    idleFor(e, 1.0);
    CHECK(std::isinf(e.snapshot().momentary), "momentary falls when paused");
    CHECK(std::fabs(e.snapshot().integrated + 23.0) < 0.15, "integrated kept when paused");
    CHECK(std::fabs(e.snapshot().truePeakMaxDb + 23.0f) < 0.2f, "measurement true peak");
    e.resetPeaks();
    CHECK(std::fabs(e.snapshot().truePeakMaxDb + 23.0f) < 0.2f, "peak reset leaves the measurement's peak");
    e.resetLoudness();
    CHECK(std::isinf(e.snapshot().integrated), "reset loudness");
    CHECK(e.snapshot().truePeakMaxDb <= kFloorDb, "loudness reset clears its true peak");

    g_context = "out of phase";
    run(e, 1.0, 0.5, 0.5, 1000.0, kPi);
    CHECK(e.snapshot().correlation < -0.99f, "inverted pair reads -1");

    g_context = "mono source";
    MeterEngine m;
    m.configure(EngineSettings());
    run(m, 1.0, 0.3, 0.3, 1000.0, 0.0, 1);
    CHECK_EQ(m.snapshot().channels, 1, "mono flagged");
    CHECK_FLOAT_EQ(m.snapshot().ch[1].rmsDb, m.snapshot().ch[0].rmsDb, "mono channels match");
    CHECK(m.snapshot().stereoSilent, "no stereo readings for mono");
}

void testSampleRateChange() {
    g_context = "sample rate change";
    MeterEngine e;
    e.configure(EngineSettings());
    run(e, 0.5, 0.5, 0.5);
    std::vector<float> buf(882 * 2, 0.25f);
    for (int f = 0; f < 60; ++f) {
        e.process(buf.data(), 735, 44100.0, 2);
        e.advance(kFrame);
    }
    CHECK(std::fabs(e.snapshot().ch[0].rmsDb + 12.04) < 0.1, "RMS valid after the switch");
}

} // namespace

int main() {
    testLevels();
    testFallAndHold();
    testClipAndTruePeak();
    testNeedle();
    testLoudnessAndStereo();
    testSampleRateChange();
    TEST_MAIN_END();
}
