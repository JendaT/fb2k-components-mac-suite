//
//  BeatGridAnalyzerTests.cpp
//  foo_jl_bpm_mac
//
//  The beat grid on synthetic audio: click tracks (steady, jittered, with a
//  phase jump, a tempo ramp, a silence), band energies on pure tones, and
//  the constant-region and BPM-snapping stages on hand-made beat lists.
//  These check the mechanics; accuracy on real music is the library pass.
//
// TEST_DEPS: src/Core/TempoEstimator.cpp
//

#include "TestHarness.h"
#include "../src/Core/BeatGridAnalyzer.h"

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <utility>
#include <vector>

using namespace bpm;

namespace {

const double kPi = 3.14159265358979323846;
const double kRate = 44100.0;

struct Rng {
    uint32_t s;
    double next() {  // -1..1
        s = s * 1664525u + 1013904223u;
        return static_cast<double>(s >> 8) / 8388608.0 - 1.0;
    }
};

struct Track {
    double seconds = 180.0;
    std::vector<double> clicks;                         // true onsets, seconds
    std::vector<std::pair<double, double>> silences;    // digital silence, seconds
};

// Mono audio: a decaying noise burst at every click over a low noise floor
std::vector<float> render(const Track &t) {
    const size_t frames = static_cast<size_t>(t.seconds * kRate);
    std::vector<float> mono(frames);
    Rng rng{ 4242 };
    for (auto &v : mono) v = static_cast<float>(0.01 * rng.next());
    for (double c : t.clicks) {
        const auto start = static_cast<size_t>(std::lround(c * kRate));
        for (size_t i = 0; i < static_cast<size_t>(0.12 * kRate) && start + i < frames; i++) {
            mono[start + i] += static_cast<float>(0.8 * std::exp(-static_cast<double>(i) / kRate / 0.02) * rng.next());
        }
    }
    for (const auto &s : t.silences) {
        for (size_t i = static_cast<size_t>(s.first * kRate); i < std::min(frames, static_cast<size_t>(s.second * kRate)); i++) {
            mono[i] = 0.0f;
        }
    }
    return mono;
}

std::vector<double> steadyClicks(double bpm, double seconds, double first = 0.05) {
    std::vector<double> out;
    for (double t = first; t < seconds - 0.2; t += 60.0 / bpm) out.push_back(t);
    return out;
}

BeatGrid analyse(const Track &t, const BeatGridHints &hints = {}) {
    const std::vector<float> audio = render(t);
    OnsetEnvelope env(kRate);
    for (size_t pos = 0; pos < audio.size(); pos += 4096) {
        env.addInterleaved(audio.data() + pos, std::min<size_t>(4096, audio.size() - pos), 1);
    }
    return analyseBeatGrid(env.values(), env.bands(), env.framesPerSecond(), env.firstFrameSeconds(), t.seconds, hints);
}

std::vector<PhraseState> phrases(const BeatGrid &g, size_t barsPerPhrase = 8) {
    std::vector<PhraseState> out;
    for (size_t b = 0; b < g.bars.size(); b += barsPerPhrase) {
        out.push_back(classifyPhrase(g.bars.data() + b, std::min(barsPerPhrase, g.bars.size() - b)));
    }
    return out;
}

const char *name(PhraseState s) {
    switch (s) {
        case PhraseState::Locked: return "L";
        case PhraseState::Drifting: return "D";
        case PhraseState::Broken: return "B";
        case PhraseState::NoPulse: return "-";
        case PhraseState::Reanchor: return "R";
    }
    return "?";
}

void printPhrases(const std::vector<PhraseState> &p) {
    printf("    phrases: ");
    for (PhraseState s : p) printf("%s", name(s));
    printf("\n");
}

// Signed distance (grid - click) of each click to its nearest grid beat
std::vector<double> phaseErrors(const BeatGrid &g, const std::vector<double> &clicks) {
    std::vector<double> out;
    const double beat = g.beatSeconds();
    for (double c : clicks) out.push_back(g.beatTime(std::lround((c - g.anchorSeconds) / beat)) - c);
    return out;
}

size_t stableCount(const BeatGrid &g) {
    size_t n = 0;
    for (const BeatRegion &r : g.regions) n += r.stable();
    return n;
}

// --- Band energies ---------------------------------------------------------

void testBands() {
    for (double hz : { 100.0, 1000.0, 8000.0 }) {
        char ctx[48];
        std::snprintf(ctx, sizeof ctx, "bands %.0f Hz", hz);
        g_context = ctx;
        std::vector<float> tone(static_cast<size_t>(2.0 * kRate));
        for (size_t i = 0; i < tone.size(); i++) tone[i] = static_cast<float>(0.5 * std::sin(2.0 * kPi * hz * i / kRate));
        OnsetEnvelope env(kRate);
        env.addInterleaved(tone.data(), tone.size(), 1);
        double sums[3] = {};
        for (int b = 0; b < 3; b++) {
            for (float v : env.bands()[b]) sums[b] += v;
        }
        CHECK(env.bands()[0].size() == env.values().size(), "one band value per envelope frame");
        const int expected = hz < kBandLowHz ? 0 : hz < kBandHighHz ? 1 : 2;
        const double total = sums[0] + sums[1] + sums[2];
        CHECK(total > 0.0, "energy");
        if (total > 0.0) {
            if (sums[expected] / total < 0.99) printf("    shares %.3f %.3f %.3f\n", sums[0] / total, sums[1] / total, sums[2] / total);
            CHECK(sums[expected] / total >= 0.99, "the tone lands in exactly one band");
        }
    }
}

// --- Stage 4 on hand-made beats ------------------------------------------

std::vector<double> grid(size_t count, double length, double first = 1.0) {
    std::vector<double> b;
    for (size_t i = 0; i < count; i++) b.push_back(first + i * length);
    return b;
}

void testConstantRegions() {
    g_context = "regions";
    {
        const auto r = detail::constantRegions(grid(100, 0.5));
        CHECK_EQ(r.size(), 1, "a straight grid is one region");
        if (!r.empty()) {
            CHECK_EQ(r[0].beatCount, 99, "of 99 beats");
            CHECK(std::fabs(r[0].beatSeconds - 0.5) < 1e-12, "at its beat length");
        }
    }
    {
        auto b = grid(100, 0.5);
        b[50] += 0.03;
        CHECK_EQ(detail::constantRegions(b).size(), 1, "one outlier is tolerated");
    }
    {
        auto b = grid(100, 0.5);
        b[40] += 0.03;
        b[60] += 0.03;
        CHECK(detail::constantRegions(b).size() > 1, "two outliers split the region");
    }
    {
        // A 20 ms bow: every beat within 13 ms of the fitted grid, but the
        // running error passes 100 ms
        auto b = grid(100, 0.5);
        for (size_t i = 0; i < b.size(); i++) b[i] += 0.02 * std::sin(kPi * i / 99.0);
        CHECK(detail::constantRegions(b).size() > 1, "steady drift over 100 ms splits it");
        // A 10 ms bow stays within 7 ms of the fitted grid and 70 ms of running error
        auto gentle = grid(100, 0.5);
        for (size_t i = 0; i < gentle.size(); i++) gentle[i] += 0.01 * std::sin(kPi * i / 99.0);
        CHECK_EQ(detail::constantRegions(gentle).size(), 1, "a gentle bow is one region");
    }
    {
        // The reason for the least-squares length: an end beat 1 ms off does
        // not break a long region
        auto b = grid(521, 60.0 / 174.0);
        b.back() -= 0.001;
        CHECK_EQ(detail::constantRegions(b).size(), 1, "a 1 ms end beat keeps 520 beats one region");
    }
    {
        auto b = grid(100, 0.5);
        b[1] += 0.03;
        const auto r = detail::constantRegions(b);
        CHECK(!r.empty() && !r[0].stable(), "the beat after a region's start must sit on the grid");
    }
    {
        const auto r = detail::constantRegions(grid(15, 0.5));
        CHECK(r.size() == 1 && !r[0].stable(), "under 16 beats is unstable");
        CHECK(!detail::masterGrid(r, grid(15, 0.5)).valid, "and anchors no grid");
    }
}

void testSnap() {
    g_context = "snap";
    CHECK_FLOAT_EQ(detail::snapBpm(119.9, 120.004, 120.1), 120.0, "whole BPM first");
    CHECK_FLOAT_EQ(detail::snapBpm(84.3, 84.5, 84.7), 84.5, "half BPM under 85");
    CHECK_FLOAT_EQ(detail::snapBpm(133.3, 133.34, 133.4), 400.0 / 3.0, "2/3 steps over 127");
    CHECK_FLOAT_EQ(detail::snapBpm(100.3, 100.33, 100.36), 301.0 / 3.0, "then thirds");
    CHECK_FLOAT_EQ(detail::snapBpm(120.08, 120.083, 120.09), 1441.0 / 12.0, "then twelfths");
    CHECK_FLOAT_EQ(detail::snapBpm(120.051, 120.0515, 120.052), 120.0515, "else the raw value");
}

void testHints() {
    g_context = "hints";
    CHECK_FLOAT_EQ(detail::applyHints(87.0, { 174.0, 0.0 }), 174.0, "a tag at double tempo doubles");
    CHECK_FLOAT_EQ(detail::applyHints(140.0, { 70.5, 0.0 }), 70.0, "half tempo within 4%");
    CHECK_FLOAT_EQ(detail::applyHints(120.0, { 100.0, 0.0 }), 120.0, "a tag far off is ignored");
    CHECK_FLOAT_EQ(detail::applyHints(87.0, { 0.0, 172.0 }), 174.0, "TIDAL when there is no tag");
}

// --- Click tracks ------------------------------------------------------------

void testClickTracks() {
    for (double tempo : { 120.0, 128.0, 174.0 }) {
        char ctx[48];
        std::snprintf(ctx, sizeof ctx, "clicks %.0f", tempo);
        g_context = ctx;
        Track t;
        t.clicks = steadyClicks(tempo, t.seconds);
        // 174 vs 87 is the prior's call (TempoEstimatorTests); the tag settles it
        const BeatGrid g = analyse(t, tempo == 174.0 ? BeatGridHints{ 174.0, 0.0 } : BeatGridHints{});
        CHECK(g.valid, "valid grid");
        if (!g.valid) continue;
        if (std::fabs(g.bpm - tempo) > 0.01) printf("    bpm %.4f\n", g.bpm);
        CHECK(std::fabs(g.bpm - tempo) <= 0.01, "BPM within 0.01");
        double mean = 0.0, worst = 0.0;
        const std::vector<double> errors = phaseErrors(g, t.clicks);
        for (double e : errors) { mean += e; worst = std::max(worst, std::fabs(e)); }
        mean /= errors.size();
        printf("    %s: phase %+.2f ms mean, %.2f ms worst; %zu regions\n", ctx, mean * 1000, worst * 1000, g.regions.size());
        CHECK(worst <= 0.005, "phase within 5 ms");
        if (g.regions.size() != 1) {
            for (const BeatRegion &r : g.regions) printf("    region %.3f s, %u beats of %.4f ms\n", r.startSeconds, r.beatCount, r.beatSeconds * 1000);
        }
        CHECK_EQ(g.regions.size(), 1, "one region");
        bool locked = true;
        for (PhraseState s : phrases(g)) locked &= s == PhraseState::Locked;
        if (!locked) printPhrases(phrases(g));
        CHECK(locked, "every phrase Locked");
        CHECK(!g.uncertain, "a steady beat is certain");
    }
}

void testJitter() {
    g_context = "jitter";
    Track t;
    Rng rng{ 99 };
    for (double c : steadyClicks(128.0, t.seconds)) t.clicks.push_back(c + 0.012 * rng.next());
    const BeatGrid g = analyse(t);
    CHECK(g.valid, "valid grid");
    if (!g.valid) return;
    // Usually one region; the 100 ms drift sum sometimes splits iid jitter
    // (3 of 12 seeds), which stays on one grid and is not flagged
    printf("    jitter: bpm %.3f, %zu regions (%zu stable)\n", g.bpm, g.regions.size(), stableCount(g));
    CHECK(std::fabs(g.bpm - 128.0) <= 0.01, "BPM within 0.01");
    bool locked = true;
    for (PhraseState s : phrases(g)) locked &= s == PhraseState::Locked;
    if (!locked) printPhrases(phrases(g));
    CHECK(locked, "every phrase Locked");
}

void testPhaseJump() {
    g_context = "phase jump";
    Track t;
    for (double c : steadyClicks(128.0, t.seconds)) t.clicks.push_back(c >= 60.0 ? c + 0.040 : c);
    const BeatGrid g = analyse(t);
    CHECK(g.valid, "valid grid");
    if (!g.valid) return;
    CHECK_EQ(stableCount(g), 2, "two stable regions");
    const std::vector<PhraseState> p = phrases(g);
    printPhrases(p);

    // The region start is flagged in the bar that holds the jump: the first shifted click
    double firstShifted = 0.0;
    for (double c : t.clicks) {
        if (c >= 60.0) { firstShifted = c; break; }
    }
    const size_t jumpBar = static_cast<size_t>(std::lround((firstShifted - g.anchorSeconds) / g.beatSeconds())) / 4;
    bool flagged = false;
    for (size_t b = 0; b < g.bars.size(); b++) {
        if (g.bars[b].flags & kBarRegionStart) flagged |= b + 1 >= jumpBar && b <= jumpBar + 1;
    }
    CHECK(flagged, "Re-anchor at the jump");

    // The master grid sits on the longer side (after the jump); the other
    // side is Broken on it, phrase for phrase
    const size_t jumpPhrase = jumpBar / 8;
    bool before = true, after = true;
    for (size_t i = 0; i < p.size(); i++) {
        if (i < jumpPhrase) before &= p[i] == PhraseState::Broken;
        if (i > jumpPhrase) after &= p[i] == PhraseState::Locked;
    }
    CHECK(p.size() > jumpPhrase && p[jumpPhrase] == PhraseState::Reanchor, "the phrase with the jump re-anchors");
    CHECK(before, "phrases off the master grid are Broken");
    CHECK(after, "phrases on it are Locked");
}

void testRamp() {
    g_context = "tempo ramp";
    Track t;
    for (double c = 0.05, bpm = 126.0; c < t.seconds - 0.2; c += 60.0 / bpm) {
        t.clicks.push_back(c);
        bpm = 126.0 + 4.0 * c / t.seconds;
    }
    const BeatGrid g = analyse(t);
    CHECK(g.valid, "valid grid");
    if (!g.valid) return;
    const std::vector<PhraseState> p = phrases(g);
    printPhrases(p);
    size_t locked = 0, drifting = 0;
    for (PhraseState s : p) { locked += s == PhraseState::Locked; drifting += s == PhraseState::Drifting; }
    CHECK(locked > 0, "Locked near the anchor");
    CHECK(drifting > 0, "Drifting away from it");
    CHECK(p.front() == PhraseState::Broken || p.back() == PhraseState::Broken, "Broken towards an end");
}

void testSilence() {
    // 20 s as the spec has it. Longer ones leave stable regions of tracker
    // beats in the silence (60 s) or where it re-syncs as the silence ends
    // (40 s); neither may read as a new grid
    const double from = 70.0;
    for (double length : { 20.0, 40.0, 60.0 }) {
        char ctx[48];
        std::snprintf(ctx, sizeof ctx, "silence %.0f s", length);
        g_context = ctx;
        Track t;
        t.clicks = steadyClicks(128.0, t.seconds);
        t.silences.push_back({ from, from + length });
        const BeatGrid g = analyse(t);
        CHECK(g.valid, "valid grid");
        if (!g.valid) continue;
        CHECK(std::fabs(g.bpm - 128.0) <= 0.01, "BPM within 0.01");
        const std::vector<PhraseState> p = phrases(g, 4);
        printPhrases(p);
        const double phraseLength = 16 * g.beatSeconds();
        bool silentNoPulse = true, noBroken = true, afterLocked = true, noReanchor = true;
        for (size_t i = 0; i < p.size(); i++) {
            const double t0 = g.anchorSeconds + i * phraseLength, t1 = t0 + phraseLength;
            if (t0 >= from && t1 <= from + length) silentNoPulse &= p[i] == PhraseState::NoPulse;
            if (t0 >= from + length) afterLocked &= p[i] == PhraseState::Locked;
            noBroken &= p[i] != PhraseState::Broken;
            noReanchor &= p[i] != PhraseState::Reanchor;
        }
        CHECK(silentNoPulse, "No pulse in the silence");
        CHECK(noBroken, "never Broken");
        CHECK(afterLocked, "the grid continues across it");
        CHECK(noReanchor, "and does not re-anchor after it");
    }
}

void testInvalid() {
    g_context = "invalid";
    const BandEnergies none;
    CHECK(!analyseBeatGrid({}, none, 172.0, 0.0, 0.0).valid, "no envelope");
    CHECK(!analyseBeatGrid(std::vector<float>(2000, 0.0f), none, 172.0, 0.0, 11.6).valid, "silence");
    CHECK(classifyPhrase(nullptr, 0) == PhraseState::NoPulse, "no bars");
}

// Hour-long mixes have ~8000 beats; the region search must stay fast
void testRegionSpeed() {
    g_context = "region speed";
    Rng rng{ 7 };
    std::vector<double> beats;
    double t = 0.0, phase = 0.0;
    for (size_t i = 0; i < 8000; i++) {
        if (i % 1500 == 1499) phase += 0.05;   // an edit every ~12 min
        beats.push_back(t + phase + 0.008 * rng.next());
        t += 60.0 / 128.0;
    }
    const auto started = std::chrono::steady_clock::now();
    const auto regions = detail::constantRegions(beats);
    const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    printf("    8000 beats: %zu regions in %.3f s\n", regions.size(), seconds);
    CHECK(seconds < 2.0, "under 2 s, instrumented");
    CHECK(detail::masterGrid(regions, beats).valid, "a master grid");
}

} // namespace

int main() {
    testBands();
    testConstantRegions();
    testSnap();
    testHints();
    testClickTracks();
    testJitter();
    testPhaseJump();
    testRamp();
    testSilence();
    testInvalid();
    testRegionSpeed();
    TEST_MAIN_END();
}
