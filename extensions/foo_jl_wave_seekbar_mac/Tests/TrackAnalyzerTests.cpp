//
//  TrackAnalyzerTests.cpp
//  foo_jl_wave_seekbar_mac
//
//  Unit tests for the per-track analysis (loudness, LRA, true peak, clips,
//  bands, correlation), column aggregation and the cache format.
//  Standalone: no SDK, no Xcode.
//
// TEST_DEPS: src/Core/WaveformData.cpp src/Core/ColumnAggregator.cpp
// TEST_LIBS: -lz
//

#include "TestHarness.h"
#include "../src/Core/TrackAnalyzer.h"
#include "../src/Core/ColumnAggregator.h"

#include <cmath>
#include <cstdint>
#include <random>
#include <vector>

using namespace analysis;

namespace {

const double kPi = 3.14159265358979323846;

#define CHECK_NEAR(actual, expected, tol, what)                                  \
    do {                                                                         \
        g_checks++;                                                             \
        double chk_a = (actual), chk_e = (expected);                            \
        if (!(std::fabs(chk_a - chk_e) <= (tol))) {                             \
            g_failures++;                                                       \
            printf("FAIL %s:%d [%s] %s: got %f, expected %f +- %f\n",           \
                   __FILE__, __LINE__, g_context.c_str(), what, chk_a, chk_e,   \
                   (double)(tol));                                              \
        }                                                                       \
    } while (0)

// Appends `seconds` of a stereo sine (peak in dBFS) to interleaved `lr`.
void appendSine(std::vector<float>& lr, double sr, double hz, double seconds, double peakDb,
                double phase = 0.0, float rSign = 1.0f) {
    const double amp = std::pow(10.0, peakDb / 20.0);
    const size_t start = lr.size() / 2, n = (size_t)(seconds * sr);
    for (size_t i = 0; i < n; ++i) {
        const float v = (float)(amp * std::sin(2.0 * kPi * hz * (double)(start + i) / sr + phase));
        lr.push_back(v);
        lr.push_back(v * rSign);
    }
}

WaveformData analyse(const std::vector<float>& lr, double sr, uint32_t channels = 2) {
    TrackAnalyzer a((uint32_t)sr, channels, lr.size() / 2);
    // Feed in uneven chunks, as a decoder would
    size_t pos = 0, frames = lr.size() / 2, chunk = 1000;
    while (pos < frames) {
        const size_t n = std::min(chunk, frames - pos);
        a.process(lr.data() + pos * 2, n, 2);
        pos += n;
        chunk = chunk == 1000 ? 4096 : 1000;
    }
    return a.finish();
}

void testIntegratedSine() {
    // EBU Tech 3341 style: a stereo 997 Hz sine at -23 dBFS reads -23 LUFS
    for (double sr : { 44100.0, 48000.0, 96000.0 }) {
        g_context = "integrated sine " + std::to_string((int)sr);
        std::vector<float> lr;
        appendSine(lr, sr, 997.0, 20.0, -23.0);
        const WaveformData w = analyse(lr, sr);
        CHECK(w.isValid(), "valid");
        CHECK_NEAR(w.summary.integrated, -23.0, 0.1, "integrated");
        CHECK_NEAR(w.summary.range, 0.0, 0.1, "LRA of a steady tone");
        CHECK_NEAR(w.summary.samplePeak, -23.0, 0.05, "sample peak");
        CHECK_NEAR(w.summary.truePeak, -23.0, 0.1, "true peak");
        CHECK_EQ(w.summary.clipRuns, 0, "no clips");
        CHECK_NEAR(w.duration, 20.0, 1e-6, "duration");
    }
}

void testGating() {
    // Quiet ends fall under the relative gate: the -23 middle sets I
    g_context = "gating";
    const double sr = 48000.0;
    std::vector<float> lr;
    appendSine(lr, sr, 997.0, 10.0, -36.0);
    appendSine(lr, sr, 997.0, 60.0, -23.0);
    appendSine(lr, sr, 997.0, 10.0, -36.0);
    CHECK_NEAR(analyse(lr, sr).summary.integrated, -23.0, 0.1, "integrated");

    // Below the absolute gate everything is ignored
    std::vector<float> quiet;
    appendSine(quiet, sr, 997.0, 10.0, -80.0);
    CHECK(std::isinf(analyse(quiet, sr).summary.integrated), "silence-level input has no integrated loudness");
}

void testLoudnessRange() {
    // EBU Tech 3342 case 1: 20 s at -20 then 20 s at -30 gives LRA 10
    g_context = "LRA";
    const double sr = 48000.0;
    std::vector<float> lr;
    appendSine(lr, sr, 1000.0, 20.0, -20.0);
    appendSine(lr, sr, 1000.0, 20.0, -30.0);
    CHECK_NEAR(analyse(lr, sr).summary.range, 10.0, 1.0, "LRA");
}

void testTruePeak() {
    // A sine at fs/4 sampled 45 degrees off its peaks: samples sit at -3 dB,
    // the waveform between them reaches 0 dBTP
    g_context = "true peak";
    const double sr = 48000.0;
    std::vector<float> lr;
    appendSine(lr, sr, sr / 4.0, 2.0, -0.5, kPi / 4.0);
    const WaveformData w = analyse(lr, sr);
    CHECK_NEAR(w.summary.samplePeak, -3.51, 0.05, "sample peak");
    CHECK_NEAR(w.summary.truePeak, -0.5, 0.3, "true peak");
    CHECK_NEAR(w.summary.plr(), w.summary.truePeak - w.summary.integrated, 1e-6, "PLR = TP - I");
}

void testClipRuns() {
    g_context = "clip runs";
    const double sr = 48000.0;
    std::vector<float> lr(2 * 48000, 0.1f);
    auto clip = [&](size_t frame, int ch, size_t len) {
        for (size_t i = 0; i < len; ++i) lr[2 * (frame + i) + ch] = (i % 2) ? -1.0f : 1.0f;
    };
    clip(1000, 0, 2);       // too short
    clip(5000, 0, 3);       // run on L
    clip(9000, 0, 5);       // run on L and R together: one event
    clip(9001, 1, 5);
    clip(20000, 1, 40);     // long run on R
    const WaveformData w = analyse(lr, sr);
    CHECK_EQ(w.summary.clipRuns, 3, "count");
    CHECK_EQ(w.clipRunFrames.size(), 3, "frames stored");
    if (w.clipRunFrames.size() == 3) {
        CHECK_EQ(w.clipRunFrames[0], 5000, "first run start");
        CHECK_EQ(w.clipRunFrames[1], 9000, "overlapping runs start with the first");
        CHECK_EQ(w.clipRunFrames[2], 20000, "long run start");
    }
}

void testBandsAndCorrelation() {
    const double sr = 48000.0;
    struct Case { double hz; int band; };
    for (Case cs : { Case{ 80.0, 0 }, Case{ 800.0, 1 }, Case{ 8000.0, 2 } }) {
        g_context = "band " + std::to_string((int)cs.hz);
        std::vector<float> lr;
        appendSine(lr, sr, cs.hz, 4.0, -12.0);
        const Columns cols = aggregateColumns(analyse(lr, sr), 8);
        CHECK(cols.bandShare[cs.band][4] > 0.9f, "energy in the expected band");
        CHECK_NEAR(cols.correlation[4], 1.0, 0.01, "identical channels");
    }

    g_context = "correlation";
    std::vector<float> inverted;
    appendSine(inverted, sr, 440.0, 4.0, -12.0, 0.0, -1.0f);
    CHECK_NEAR(aggregateColumns(analyse(inverted, sr), 8).correlation[4], -1.0, 0.01, "inverted channels");

    std::mt19937 rng(1);
    std::uniform_real_distribution<float> noise(-0.3f, 0.3f);
    std::vector<float> unrelated(2 * 4 * 48000);
    for (auto& x : unrelated) x = noise(rng);
    CHECK_NEAR(aggregateColumns(analyse(unrelated, sr), 8).correlation[4], 0.0, 0.05, "independent noise");
}

void testColumns() {
    g_context = "columns";
    const double sr = 44100.0;
    std::vector<float> lr;
    appendSine(lr, sr, 441.0, 10.0, 20.0 * std::log10(0.5));
    const WaveformData w = analyse(lr, sr);

    for (size_t columns : { (size_t)50, (size_t)3000 }) {   // merging and interpolating
        const Columns c = aggregateColumns(w, columns);
        CHECK_EQ(c.count, columns, "count");
        const size_t mid = columns / 2;
        CHECK_NEAR(c.max[0][mid], 0.5, 0.01, "max");
        CHECK_NEAR(c.min[1][mid], -0.5, 0.01, "min");
        CHECK_NEAR(c.rms[0][mid], 0.5 / std::sqrt(2.0), 0.005, "rms");
        CHECK_NEAR(c.peakDb[mid], -6.02, 0.1, "peak dBFS");
        CHECK_NEAR(c.crestDb[mid], 3.01, 0.1, "crest of a sine");
        CHECK_NEAR(c.lufs[mid], w.summary.integrated, 0.2, "short-term matches a steady tone");
    }

    g_context = "silence";
    const WaveformData silent = analyse(std::vector<float>(2 * 44100, 0.0f), sr);
    CHECK(silent.isValid(), "valid");
    CHECK(std::isinf(silent.summary.integrated), "no loudness");
    CHECK_NEAR(silent.summary.range, 0.0, 1e-9, "no range");
    const Columns c = aggregateColumns(silent, 10);
    CHECK(std::isnan(c.lufs[5]) && std::isnan(c.crestDb[5]) && std::isnan(c.correlation[5]), "readout undefined");
    CHECK(std::isinf(c.level[0][5]), "level -inf");
}

void testMixdown() {
    // L at 0.5 and R silent: the mix keeps the widest peaks and halves the power
    g_context = "mixdown";
    const double sr = 48000.0;
    std::vector<float> lr;
    for (size_t i = 0; i < 48000 * 4; ++i) {
        lr.push_back(0.5f * (float)std::sin(2.0 * kPi * 440.0 * i / sr));
        lr.push_back(0.0f);
    }
    const Columns stereo = aggregateColumns(analyse(lr, sr), 16);
    const Columns mono = mixdown(stereo);
    CHECK_EQ(mono.channels, 1, "one channel");
    CHECK_NEAR(mono.max[0][8], 0.5, 0.01, "widest maximum");
    CHECK_NEAR(mono.min[0][8], -0.5, 0.01, "widest minimum");
    CHECK_NEAR(mono.rms[0][8], stereo.rms[0][8] / std::sqrt(2.0), 0.002, "power mean of RMS");
    CHECK_NEAR(mono.level[0][8], stereo.level[0][8] - 3.01, 0.05, "level 3 dB down");
    CHECK(mono.max[1].empty(), "second channel dropped");
    CHECK_EQ(mixdown(mono).count, mono.count, "mono passes through");
}

void testMonoAndBlocks() {
    g_context = "mono";
    const double sr = 48000.0;
    std::vector<float> mono(48000);
    for (size_t i = 0; i < mono.size(); ++i) mono[i] = 0.25f * (float)std::sin(2.0 * kPi * 997.0 * i / sr);
    TrackAnalyzer stereo((uint32_t)sr, 2, mono.size());
    stereo.process(mono.data(), mono.size(), 1);   // a mono chunk feeds both channels
    const WaveformData w = stereo.finish();
    CHECK_EQ(w.channelCount, 2, "channels");
    CHECK_NEAR(w.blockMax[1][10], w.blockMax[0][10], 1e-6, "R mirrors L");
    CHECK_NEAR(aggregateColumns(w, 4).correlation[2], 1.0, 0.01, "correlated");

    g_context = "double samples";
    std::vector<double> asDouble(mono.begin(), mono.end());
    TrackAnalyzer fromDouble((uint32_t)sr, 2, asDouble.size());
    fromDouble.process(asDouble.data(), asDouble.size(), 1);
    CHECK_NEAR(fromDouble.finish().summary.integrated, w.summary.integrated, 1e-4, "same as float input");

    g_context = "block size";
    TrackAnalyzer a(44100, 2, 44100ull * 3600);
    std::vector<float> one(2, 0.0f);
    a.process(one.data(), 1, 2);
    CHECK(a.finish().blockFrames > kMinBlockFrames, "long tracks get larger blocks");
    TrackAnalyzer b(44100, 2, 44100ull * 60);
    b.process(one.data(), 1, 2);
    CHECK_EQ(b.finish().blockFrames, kMinBlockFrames, "short tracks keep 1024");
}

void testCacheRoundTrip() {
    g_context = "cache";
    const double sr = 44100.0;
    std::vector<float> lr;
    appendSine(lr, sr, 997.0, 5.0, -10.0);
    appendSine(lr, sr, 3000.0, 5.0, -30.0, 0.3, -1.0f);
    lr[2 * 1000] = lr[2 * 1001] = lr[2 * 1002] = 1.0f;
    const WaveformData w = analyse(lr, sr);

    const std::vector<uint8_t> blob = w.compress();
    CHECK(!blob.empty(), "compresses");
    const auto back = WaveformData::decompress(blob.data(), blob.size());
    CHECK(back.has_value(), "decompresses");
    if (!back) return;
    CHECK_EQ(back->blockCount(), w.blockCount(), "blocks");
    CHECK_EQ(back->hopCount(), w.hopCount(), "hops");
    CHECK_EQ(back->clipRunFrames.size(), w.clipRunFrames.size(), "clip runs");
    CHECK_NEAR(back->summary.integrated, w.summary.integrated, 1e-6, "summary kept exactly");
    CHECK_NEAR(back->blockMax[0][100], w.blockMax[0][100], 1e-4, "sample quantization");
    CHECK_NEAR(10 * std::log10(back->hopKms[1][30]), 10 * std::log10(w.hopKms[1][30]), 0.01, "level quantization");

    const Columns a = aggregateColumns(w, 200), b = aggregateColumns(*back, 200);
    CHECK_NEAR(a.lufs[150], b.lufs[150], 0.02, "readout survives the cache");
    CHECK_NEAR(a.correlation[150], b.correlation[150], 0.001, "correlation survives the cache");

    CHECK(!WaveformData::decompress(blob.data(), blob.size() / 2).has_value(), "truncated blob rejected");
    std::vector<uint8_t> v1 = blob;
    v1[4] ^= 0xFF;
    CHECK(!WaveformData::decompress(v1.data(), v1.size()).has_value(), "corrupt blob rejected");
}

} // namespace

int main() {
    testIntegratedSine();
    testGating();
    testLoudnessRange();
    testTruePeak();
    testClipRuns();
    testBandsAndCorrelation();
    testColumns();
    testMixdown();
    testMonoAndBlocks();
    testCacheRoundTrip();
    TEST_MAIN_END();
}
