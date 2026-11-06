//
//  TrackAnalyzerTests.cpp
//  foo_jl_wave_seekbar_mac
//
//  Unit tests for the per-track analysis (loudness, LRA, true peak, clips,
//  bands, correlation, multichannel weighting, segments), column aggregation
//  and the cache format.
//  Standalone: no SDK, no Xcode.
//
// TEST_DEPS: src/Core/WaveformData.cpp src/Core/ColumnAggregator.cpp
// TEST_LIBS: -lz
//

#include "TestHarness.h"
#include "../src/Core/TrackAnalyzer.h"
#include "../src/Core/ColumnAggregator.h"

#include <zlib.h>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <numeric>
#include <random>
#include <vector>

using namespace waveseek::analysis;

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

// `channels`-wide interleaved audio with L of `lr` on the channels in
// `fromL` and silence on the others
std::vector<float> spread(const std::vector<float>& lr, uint32_t channels, const std::vector<int>& fromL) {
    const size_t frames = lr.size() / 2;
    std::vector<float> out(frames * channels, 0.0f);
    for (size_t i = 0; i < frames; ++i) {
        for (int ch : fromL) out[i * channels + ch] = lr[2 * i];
    }
    return out;
}

// One sequential pass over `stride`-channel audio in chunks cycling through
// `chunks` frames
WaveformData analyseInChunks(const std::vector<float>& samples, uint32_t stride, uint32_t sr,
                             std::initializer_list<size_t> chunks, const float* weights = nullptr,
                             uint32_t channels = 2) {
    const size_t frames = samples.size() / stride;
    TrackAnalyzer a(sr, channels, frames);
    size_t pos = 0;
    for (size_t i = 0; pos < frames; ++i) {
        const size_t n = std::min(*(chunks.begin() + i % chunks.size()), frames - pos);
        a.process(samples.data() + pos * stride, n, stride, weights);
        pos += n;
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

    // Two equal samples per channel at the very end overshoot between them;
    // the end of the track reads as if silence followed
    g_context = "true peak at the end";
    std::vector<float> end(2 * 48000, 0.0f);
    for (size_t i = end.size() - 4; i < end.size(); ++i) end[i] = 0.9f;
    std::vector<float> followed = end;
    followed.resize(end.size() + 2 * 48000, 0.0f);
    const WaveformData atEnd = analyse(end, sr), beforeSilence = analyse(followed, sr);
    CHECK(atEnd.summary.truePeak == beforeSilence.summary.truePeak, "same as followed by silence");
    CHECK(atEnd.summary.truePeak > atEnd.summary.samplePeak + 1.0f, "the overshoot counts");
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
        CHECK(cols.tintShare[cs.band][4] > 0.9f, "tint share in the expected band");
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
        CHECK_NEAR(c.momentary[0][mid], c.level[0][mid], 0.1, "momentary equals short-term on a steady tone");
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
    CHECK_NEAR(mono.momentary[0][8], stereo.momentary[0][8] - 3.01, 0.05, "momentary 3 dB down");
    CHECK(mono.momentary[1].empty(), "second momentary dropped");
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
    CHECK(a.finish().blockFrames > kTargetBlockFrames, "long tracks get larger blocks");
    TrackAnalyzer b(44100, 2, 44100ull * 60);
    b.process(one.data(), 1, 2);
    CHECK_EQ(b.finish().blockFrames, 882, "short tracks: the divisor of the 4410-frame hop nearest 1024");
    CHECK_EQ(blockFramesFor(48000ull * 60, 48000), 960, "48 kHz: 4800 / 5");
}

void testMonoChunks() {
    // A decoder handing mono chunks to a stereo analysis: one channel of
    // weight 1, not the same signal twice (+3 LU)
    g_context = "mono chunks";
    const double sr = 48000.0;
    std::vector<float> lr;
    appendSine(lr, sr, 997.0, 10.0, -23.0);
    std::vector<float> mono(lr.size() / 2);
    for (size_t i = 0; i < mono.size(); ++i) mono[i] = lr[2 * i];

    const WaveformData asStereo = analyseInChunks(mono, 1, (uint32_t)sr, { 1152, 4096 });
    const WaveformData asMono = analyseInChunks(mono, 1, (uint32_t)sr, { 1152, 4096 }, nullptr, 1);
    CHECK_EQ(asStereo.channelCount, 2, "drawn on both lanes");
    CHECK(asStereo.blockMax[0] == asStereo.blockMax[1] && asStereo.hopKms[0] == asStereo.hopKms[1], "R mirrors L");
    CHECK_NEAR(asStereo.summary.integrated, -26.01, 0.1, "one channel: 3 dB under the stereo sine");
    CHECK_NEAR(analyse(lr, sr).summary.integrated, -23.0, 0.1, "the stereo sine");
    CHECK(asStereo.summary.integrated == asMono.summary.integrated, "same loudness as a mono analysis");
    CHECK(asStereo.hopKmsSum == asMono.hopKmsSum, "same summed power as a mono analysis");
    CHECK_NEAR(aggregateColumns(asStereo, 10).lufs[5], asStereo.summary.integrated, 0.2, "readout counts it once");
}

void testMultichannel() {
    // 5.1 (L R C LFE Ls Rs): BS.1770 sums L, R, C at 1, Ls and Rs at 1.41,
    // and leaves LFE out
    g_context = "5.1";
    const double sr = 48000.0;
    const float weights[6] = { 1.0f, 1.0f, 1.0f, 0.0f, 1.41f, 1.41f };
    std::vector<float> lr;
    appendSine(lr, sr, 997.0, 10.0, -23.0);
    auto run = [&](const std::vector<int>& from) {
        return analyseInChunks(spread(lr, 6, from), 6, (uint32_t)sr, { 1024, 4096 }, weights);
    };

    const WaveformData all = run({ 0, 1, 2, 3, 4, 5 });
    // Each channel as loud as one of the -23 LUFS stereo sine: (3 + 2 x 1.41) / 2 times its power
    CHECK_NEAR(all.summary.integrated, -23.0 + 10.0 * std::log10((3.0 + 2 * 1.41) / 2.0), 0.1, "all six");
    CHECK_EQ(all.channelCount, 2, "draws front L/R");
    CHECK_NEAR(all.summary.truePeak, -23.0, 0.1, "true peak");
    CHECK_NEAR(run({ 2 }).summary.integrated, -26.01, 0.1, "centre only");
    CHECK_NEAR(run({ 4 }).summary.integrated, -26.01 + 10.0 * std::log10(1.41), 0.1, "one surround channel");
    const WaveformData lfe = run({ 3 });
    CHECK(std::isinf(lfe.summary.integrated), "LFE only: no loudness");
    CHECK_NEAR(lfe.summary.truePeak, -23.0, 0.1, "LFE still has a true peak");
    CHECK_NEAR(lfe.summary.samplePeak, -23.0, 0.05, "and a sample peak");
    CHECK(std::isnan(aggregateColumns(lfe, 10).lufs[5]), "LFE only: no LUFS readout");
    CHECK_NEAR(aggregateColumns(run({ 2 }), 10).lufs[5], -26.01, 0.2, "readout counts the centre");

    // A clip run and an inter-sample peak on a rear channel only
    std::vector<float> six = spread(lr, 6, { 0, 1 });
    for (size_t f : { 30000, 30001, 30002 }) six[f * 6 + 5] = 1.0f;
    six[50000 * 6 + 4] = six[50001 * 6 + 4] = 0.9f;
    const WaveformData rear = analyseInChunks(six, 6, (uint32_t)sr, { 4096 }, weights);
    CHECK_EQ(rear.summary.clipRuns, 1, "clip run on Rs");
    CHECK(rear.summary.truePeak > 0.0f, "inter-sample peak on Ls over 0 dBTP");
    CHECK_NEAR(rear.summary.samplePeak, 0.0, 1e-6, "sample peak on Rs");
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

    // Float sources past full scale keep their peaks through the cache
    g_context = "cache above 0 dBFS";
    std::vector<float> hot;
    appendSine(hot, sr, 441.0, 5.0, 1.0);
    const WaveformData fresh = analyse(hot, sr);
    const std::vector<uint8_t> hotBlob = fresh.compress();
    const auto reloaded = WaveformData::decompress(hotBlob.data(), hotBlob.size());
    CHECK(reloaded.has_value(), "decompresses");
    if (reloaded) {
        const Columns f = aggregateColumns(fresh, 100), r = aggregateColumns(*reloaded, 100);
        CHECK_NEAR(f.peakDb[50], 1.0, 0.01, "fresh peak +1 dBFS");
        CHECK_NEAR(r.peakDb[50], f.peakDb[50], 0.01, "reloaded peak");
        CHECK_NEAR(r.crestDb[50], f.crestDb[50], 0.01, "reloaded crest");
        CHECK_NEAR(reloaded->blockMin[1][100], fresh.blockMin[1][100], 1e-4, "negative peak");
    }

    g_context = "cache of silence";
    const WaveformData silent = analyse(std::vector<float>(2 * 44100, 0.0f), sr);
    const std::vector<uint8_t> silentBlob = silent.compress();
    const auto silentBack = WaveformData::decompress(silentBlob.data(), silentBlob.size());
    CHECK(silentBack.has_value() && std::isinf(silentBack->summary.integrated)
          && std::isinf(silentBack->summary.truePeak), "-inf levels are kept");
}

// `blob` with `size` bytes at `offset` of the uncompressed payload replaced
std::vector<uint8_t> patchBlob(const std::vector<uint8_t>& blob, size_t offset, const void* bytes, size_t size) {
    uint32_t rawSize;
    std::memcpy(&rawSize, blob.data(), 4);
    std::vector<uint8_t> raw(rawSize);
    uLongf rawLen = rawSize;
    if (uncompress(raw.data(), &rawLen, blob.data() + 4, (uLong)(blob.size() - 4)) != Z_OK) return {};
    std::memcpy(raw.data() + offset, bytes, size);
    uLongf packedSize = compressBound(rawSize);
    std::vector<uint8_t> out(packedSize + 4);
    std::memcpy(out.data(), &rawSize, 4);
    if (compress2(out.data() + 4, &packedSize, raw.data(), rawSize, Z_DEFAULT_COMPRESSION) != Z_OK) return {};
    out.resize(packedSize + 4);
    return out;
}

void testCacheRejectsNonFinite() {
    g_context = "cache validation";
    std::vector<float> lr;
    appendSine(lr, 44100.0, 997.0, 3.0, -10.0);
    const WaveformData w = analyse(lr, 44100.0);
    const std::vector<uint8_t> blob = w.compress();

    // Payload: version, channels, rate (4 bytes each), then the duration
    const size_t durationAt = 12, integratedAt = 40, truePeakAt = 48;
    struct Case { double duration; const char* what; };
    for (Case cs : { Case{ INFINITY, "+inf duration rejected" }, Case{ NAN, "NaN duration rejected" },
                     Case{ -1.0, "negative duration rejected" }, Case{ 1e300, "duration past the arrays rejected" } }) {
        const std::vector<uint8_t> bad = patchBlob(blob, durationAt, &cs.duration, sizeof cs.duration);
        CHECK(!bad.empty() && !WaveformData::decompress(bad.data(), bad.size()).has_value(), cs.what);
    }
    const float nan = NAN, inf = INFINITY;
    std::vector<uint8_t> bad = patchBlob(blob, integratedAt, &nan, sizeof nan);
    CHECK(!WaveformData::decompress(bad.data(), bad.size()).has_value(), "NaN loudness rejected");
    bad = patchBlob(blob, truePeakAt, &inf, sizeof inf);
    CHECK(!WaveformData::decompress(bad.data(), bad.size()).has_value(), "+inf true peak rejected");
    const double same = w.duration;
    bad = patchBlob(blob, durationAt, &same, sizeof same);
    CHECK(WaveformData::decompress(bad.data(), bad.size()).has_value(), "the patch itself keeps a valid blob");

    WaveformData endless = w;
    endless.duration = INFINITY;
    CHECK(!endless.isValid(), "infinite duration invalid");
    CHECK_EQ(aggregateColumns(endless, 100).count, 0, "and not aggregated");
}

void testColumnEdges() {
    // 100 blocks of 10 frames; one loud block shows in exactly one column,
    // the one holding its centre, and every column has blocks
    g_context = "column edges";
    WaveformData w;
    w.channelCount = 1;
    w.sampleRate = 1000;
    w.duration = 1.0;
    w.blockFrames = 10;
    w.hopFrames = 100;
    for (auto* v : { &w.hopKms[0], &w.hopMs[0], &w.hopKmsSum, &w.hopBand[0], &w.hopBand[1], &w.hopBand[2] }) {
        v->assign(10, 0.0f);
    }
    w.blockMin[0].assign(100, -0.5f);
    w.blockRms[0].assign(100, 0.25f);
    bool once = true, centred = true, filled = true;
    for (size_t loud = 0; loud < 100; ++loud) {
        w.blockMax[0].assign(100, 0.5f);
        w.blockMax[0][loud] = 1.0f;
        for (size_t columns : { 70, 41, 99, 100 }) {
            const Columns c = aggregateColumns(w, columns);
            size_t shown = 0, at = 0;
            for (size_t i = 0; i < columns; ++i) {
                if (c.max[0][i] > 0.75f) { ++shown; at = i; }
                filled &= c.rms[0][i] == 0.25f;
            }
            once &= shown == 1;
            const double centre = (loud + 0.5) * 10.0, perColumn = 1000.0 / columns;
            centred &= centre >= at * perColumn && centre < (at + 1) * perColumn;
        }
    }
    CHECK(once, "a block shows in one column");
    CHECK(centred, "the column holding its centre");
    CHECK(filled, "no column left without blocks");
}

void testPlanSegments() {
    g_context = "plan";
    const uint32_t sr = 44100;
    const uint64_t total = (uint64_t)sr * 7200;   // a 2 h mix
    const std::vector<Segment> segs = planSegments(total, sr);
    CHECK(segs.size() > 1 && segs.size() <= kMaxSegments, "split into at most kMaxSegments");
    const uint64_t unit = std::lcm<uint64_t>(blockFramesFor(total, sr), hopFramesFor(sr));
    bool aligned = true, longEnough = true, contiguous = true;
    for (size_t i = 0; i < segs.size(); ++i) {
        aligned &= segs[i].start % unit == 0;
        if (i + 1 < segs.size()) {
            longEnough &= segs[i].end - segs[i].start >= (uint64_t)(kMinSegmentSeconds * sr);
            contiguous &= segs[i].end == segs[i + 1].start;
        }
    }
    CHECK(aligned, "boundaries on the block and hop grid");
    CHECK(longEnough, "segments at least 30 s");
    CHECK(contiguous, "segments meet");
    CHECK(segs.front().start == 0 && segs.back().end == UINT64_MAX, "cover the whole track");

    CHECK_EQ(planSegments((uint64_t)sr * 25, sr).size(), 1, "short tracks stay whole");
    CHECK_EQ(planSegments(0, sr).size(), 1, "empty track");
    CHECK_EQ(planSegments(total, sr, 1).size(), 1, "one segment allowed");

    // Long tracks get (nearly) the full count at any rate and length; blocks
    // stay on the hop grid and within kMaxBlocks
    bool many = true, onHopGrid = true, bounded = true;
    for (uint32_t rate : { 22050u, 44100u, 48000u, 88200u, 96000u, 192000u }) {
        for (double seconds : { 3600.0, 3604.0, 3620.0, 4321.0, 5000.0, 6007.0, 7200.0 }) {
            const uint64_t frames = (uint64_t)(rate * seconds);
            const uint64_t block = blockFramesFor(frames, rate), hop = hopFramesFor(rate);
            const size_t count = planSegments(frames, rate).size();
            many &= count >= 32 && count <= kMaxSegments;
            onHopGrid &= block % hop == 0 || hop % block == 0;
            bounded &= (frames + block - 1) / block <= kMaxBlocks;
            if (count < 32) printf("  %u Hz, %.0f s: %zu segments\n", rate, seconds, count);
        }
    }
    CHECK(many, "1-2 h tracks get at least 32 segments");
    CHECK(onHopGrid, "blocks divide the hop or are multiples of it");
    CHECK(bounded, "at most kMaxBlocks blocks");
}

// Analyses interleaved `samples` (`stride` channels) the way the scanner
// does in parallel: each segment with its own analyser, seeking to the
// pre-roll before it and reading the clip-run tail after it in `chunk`-frame
// reads, then joined
WaveformData analyseSegmented(const std::vector<float>& samples, uint32_t stride, uint32_t sr,
                              const std::vector<Segment>& segs, size_t chunk, const float* weights = nullptr) {
    const uint64_t total = samples.size() / stride;
    const uint64_t preroll = (uint64_t)(kSegmentPrerollSeconds * sr);
    std::vector<WaveformData> parts;
    for (const Segment& seg : segs) {
        TrackAnalyzer a(sr, 2, total);
        a.setRange(seg.start, seg.end);
        const uint64_t from = seg.start > preroll ? seg.start - preroll : 0;
        const uint64_t to = seg.end == UINT64_MAX ? total : std::min(total, seg.end + kClipRunLength - 1);
        a.setPosition(from);
        for (uint64_t pos = from; pos < to; pos += chunk) {
            const uint64_t n = std::min<uint64_t>(chunk, to - pos);
            a.process(samples.data() + pos * stride, (size_t)n, stride, weights);
        }
        parts.push_back(a.finish());
    }
    return TrackAnalyzer::merge(std::move(parts));
}

// Every array and the summary, bit for bit
void checkIdentical(const WaveformData& one, const WaveformData& joined) {
    CHECK(joined.isValid(), "valid");
    CHECK_EQ(joined.channelCount, one.channelCount, "channels");
    CHECK_EQ(joined.blockFrames, one.blockFrames, "block size");
    CHECK(joined.duration == one.duration, "duration");
    for (int ch = 0; ch < 2; ++ch) {
        CHECK(joined.blockMin[ch] == one.blockMin[ch], "block minima");
        CHECK(joined.blockMax[ch] == one.blockMax[ch], "block maxima");
        CHECK(joined.blockRms[ch] == one.blockRms[ch], "block RMS");
        CHECK(joined.hopKms[ch] == one.hopKms[ch], "K-weighted hops");
        CHECK(joined.hopMs[ch] == one.hopMs[ch], "plain power hops");
    }
    CHECK(joined.hopKmsSum == one.hopKmsSum, "summed K-weighted hops");
    CHECK(joined.hopLR == one.hopLR, "L*R hops");
    for (int b = 0; b < 3; ++b) CHECK(joined.hopBand[b] == one.hopBand[b], "band hops");
    CHECK(joined.clipRunFrames == one.clipRunFrames, "clip runs");
    CHECK(joined.summary.integrated == one.summary.integrated, "integrated");
    CHECK(joined.summary.range == one.summary.range, "LRA");
    CHECK(joined.summary.truePeak == one.summary.truePeak, "true peak");
    CHECK(joined.summary.samplePeak == one.summary.samplePeak, "sample peak");
    CHECK_EQ(joined.summary.clipRuns, one.summary.clipRuns, "clip count");
}

void testSegmentsMatchOnePass() {
    // As the scanner runs a 2.5 min track at 44.1 kHz: real segment plan,
    // 1 s pre-roll, decoder chunks of 1152 against 4096-frame reads
    g_context = "segments";
    const uint32_t sr = 44100;
    const uint64_t total = (uint64_t)sr * 150;
    std::mt19937 rng(7);
    std::normal_distribution<float> noise(0.0f, 0.05f);
    std::vector<float> lr(total * 2);
    for (uint64_t i = 0; i < total; ++i) {
        const double t = (double)i / sr;
        const float env = 0.2f + 0.6f * (float)std::fabs(std::sin(t * 0.3));
        lr[2 * i] = env * (float)std::sin(2.0 * kPi * (60.0 + 40.0 * std::fmod(t, 20.0)) * t) + noise(rng);
        lr[2 * i + 1] = 0.7f * lr[2 * i] + noise(rng);
        if (std::fmod(t, 37.0) > 30.0) lr[2 * i] = lr[2 * i + 1] = 0.0f;   // silences: decaying filters
    }

    const std::vector<Segment> segs = planSegments(total, sr);
    CHECK_EQ(segs.size(), 5, "30 s segments");
    // Clip runs at the boundaries: one straddling the first, one starting two
    // frames before the second (it only reaches three frames after), one on
    // R just inside, one on R straddling the third
    const uint64_t b = segs[1].start, b2 = segs[2].start, b3 = segs[3].start;
    for (uint64_t f : { b - 1, b, b + 1, b + 2 }) lr[2 * f] = 1.0f;
    for (uint64_t f : { b + 50, b + 51, b + 52 }) lr[2 * f + 1] = -1.0f;
    for (uint64_t f : { b2 - 2, b2 - 1, b2 }) lr[2 * f] = 1.0f;
    for (uint64_t f : { b3 - 1, b3, b3 + 1, b3 + 2, b3 + 3 }) lr[2 * f + 1] = -1.0f;
    // A burst in the last samples, for the true-peak flush
    for (uint64_t f = total - 3; f < total; ++f) lr[2 * f] = lr[2 * f + 1] = 0.95f;

    const WaveformData one = analyseInChunks(lr, 2, sr, { 1152, 4096 });
    CHECK_EQ(one.clipRunFrames.size(), 4, "the four planted runs");
    checkIdentical(one, analyseSegmented(lr, 2, sr, segs, 4096));
    checkIdentical(one, analyseSegmented(lr, 2, sr, segs, 1152));

    // 5.1, weighted, with more segments than the scanner would make
    g_context = "segments 5.1";
    const uint32_t sr6 = 48000;
    const float weights[6] = { 1.0f, 1.0f, 1.0f, 0.0f, 1.41f, 1.41f };
    const uint64_t total6 = (uint64_t)sr6 * 20;
    std::vector<float> six(total6 * 6);
    for (uint64_t i = 0; i < total6; ++i) {
        const double t = (double)i / sr6;
        for (int ch = 0; ch < 6; ++ch) {
            six[6 * i + ch] = (0.1f + 0.1f * ch) * (float)std::sin(2.0 * kPi * (50.0 + 300.0 * ch) * t) + noise(rng);
        }
    }
    const std::vector<Segment> segs6 = planSegments(total6, sr6, kMaxSegments, 5.0);
    CHECK_EQ(segs6.size(), 4, "5 s segments");
    for (uint64_t f : { segs6[2].start - 1, segs6[2].start, segs6[2].start + 1 }) six[6 * f + 4] = 1.0f;
    const WaveformData one6 = analyseInChunks(six, 6, sr6, { 1152, 4096 }, weights);
    CHECK_EQ(one6.clipRunFrames.size(), 1, "the run on Ls");
    checkIdentical(one6, analyseSegmented(six, 6, sr6, segs6, 4096, weights));
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
    testMonoChunks();
    testMultichannel();
    testCacheRoundTrip();
    testCacheRejectsNonFinite();
    testColumnEdges();
    testPlanSegments();
    testSegmentsMatchOnePass();
    TEST_MAIN_END();
}
