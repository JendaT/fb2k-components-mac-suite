//
//  PhraseMarkersTests.cpp
//  foo_wave_seekbar_mac
//
//  Phrase markers from a beat grid: positions, states, offsets, the
//  re-anchor point, the phrase phase and thinning.
//

#include "TestSupport.h"
#include "../src/Core/PhraseMarkers.h"

using namespace waveseek;

namespace {

// 128 BPM from 0.1 s, `bars` locked bars
PhraseGrid lockedGrid(size_t bars) {
    PhraseGrid g;
    g.summary.bpm = 128.0;
    g.summary.anchor_seconds = 0.1;
    g.summary.bar_phase = -1;
    g.summary.phrase_phase_bars = -1;
    g.bars.assign(bars, jl_bar_stat{ 0, 4, static_cast<uint8_t>(jl_pulse_unit), 0 });
    g.regions.push_back({ 0.1, 60.0 / 128.0, static_cast<uint32_t>(bars * 4), 0 });
    return g;
}

void testPositions() {
    TEST_CASE("positions");
    const PhraseGrid g = lockedGrid(64);
    const auto m = phraseMarkers(g, 32);
    CHECK(m.size() == 8, "64 bars make 8 phrases of 32 beats");
    CHECK_NEAR(m[0].seconds, 0.1, 1e-9, "the first starts on beat 0");
    CHECK_NEAR(m[1].seconds - m[0].seconds, 32 * 60.0 / 128.0, 1e-9, "32 beats apart");
    CHECK(m[3].startBar == 24, "phrase 3 starts on bar 24");
    CHECK(phraseMarkers(g, 16).size() == 16, "16-beat phrases: twice as many");
    bool locked = true;
    for (const auto &p : m) locked &= p.state == jl_phrase_locked;
    CHECK(locked, "all locked");
    CHECK_NEAR(lockedPhraseShare(m), 1.0, 1e-12, "100% locked");

    const auto partial = phraseMarkers(lockedGrid(20), 32);
    CHECK(partial.size() == 3, "a partial last phrase still gets its marker");
}

void testStates() {
    TEST_CASE("states");
    PhraseGrid g = lockedGrid(64);
    for (size_t b = 8; b < 16; ++b) g.bars[b] = { 15, 3, static_cast<uint8_t>(jl_pulse_unit), 0 };   // drifting
    for (size_t b = 16; b < 24; ++b) g.bars[b] = { -40, 0, static_cast<uint8_t>(jl_pulse_unit), 0 }; // broken
    for (size_t b = 24; b < 32; ++b) g.bars[b] = { 0, 0, 8, 0 };                                       // no pulse
    g.bars[36].flags = jl_bar_region_start;
    const double newGrid = 0.1 + 36 * 4 * 60.0 / 128.0 + 0.04;
    g.regions.push_back({ newGrid, 60.0 / 128.0, 100, 0 });
    const auto m = phraseMarkers(g, 32);
    CHECK(m[1].state == jl_phrase_drifting, "drifting");
    CHECK(m[1].offsetMs == 15, "with its median offset");
    CHECK(m[2].state == jl_phrase_broken, "broken");
    CHECK(m[2].offsetMs == -40, "early by 40 ms");
    CHECK(m[3].state == jl_phrase_no_pulse, "no pulse");
    CHECK(m[4].state == jl_phrase_reanchor, "re-anchor");
    CHECK_NEAR(m[4].reanchorSeconds, newGrid, 1e-9, "at the new region's first beat");
    CHECK(std::isnan(m[0].reanchorSeconds), "no re-anchor point elsewhere");
    CHECK_NEAR(lockedPhraseShare(m), 4.0 / 8.0, 1e-12, "4 of 8 phrases locked");

    // A flag without a matching region falls back to the flagged bar
    PhraseGrid flagOnly = lockedGrid(16);
    flagOnly.bars[10].flags = jl_bar_region_start;
    const auto f = phraseMarkers(flagOnly, 32);
    CHECK_NEAR(f[1].reanchorSeconds, 0.1 + 10 * 4 * 60.0 / 128.0, 1e-9, "the flagged bar");
}

void testPhrasePhase() {
    TEST_CASE("phrase phase");
    PhraseGrid g = lockedGrid(64);
    g.summary.phrase_phase_bars = 3;
    g.summary.phrase_confidence = 0.5f;
    CHECK(phraseMarkers(g, 32)[0].startBar == 3, "a confident phase moves the count");
    CHECK(phraseMarkers(g, 16)[0].startBar == 3, "for 16-beat phrases too");
    g.summary.phrase_phase_bars = 6;
    CHECK(phraseMarkers(g, 16)[0].startBar == 2, "modulo the shorter phrase");
    g.summary.phrase_confidence = 0.1f;
    CHECK(phraseMarkers(g, 32)[0].startBar == 0, "an unsure phase is ignored");
}

void testThinning() {
    TEST_CASE("thinning");
    // 4 min at 128 BPM in 800 pt: a beat is 1.56 pt, 16 beats 25 pt
    CHECK(thinnedPhraseBeats(32, 128.0, 240.0, 800.0) == 32, "far enough apart");
    CHECK(thinnedPhraseBeats(16, 128.0, 240.0, 800.0) == 16, "16 beats: 25 pt");
    // 20 min in 600 pt: 16 beats are 3.75 pt, 32 beats 7.5 pt
    CHECK(thinnedPhraseBeats(16, 128.0, 1200.0, 600.0) == 32, "closer than 6 pt doubles");
    // A 3 h mix in 800 pt: 32 beats are 0.83 pt, doubled to 256 (6.7 pt)
    CHECK(thinnedPhraseBeats(32, 128.0, 3 * 3600.0, 800.0) == 256, "long mixes thin out");
    CHECK(thinnedPhraseBeats(32, 128.0, 3 * 3600.0, 800.0, 8.0) == 32, "zoomed in they come back");
    CHECK(thinnedPhraseBeats(32, 0.0, 240.0, 800.0) == 32, "no grid");
}

void testEmpty() {
    TEST_CASE("empty");
    CHECK(phraseMarkers(PhraseGrid(), 32).empty(), "no grid, no markers");
    CHECK_NEAR(lockedPhraseShare({}), 0.0, 1e-12, "no markers, nothing locked");
}

} // namespace

int main() {
    testPositions();
    testStates();
    testPhrasePhase();
    testThinning();
    testEmpty();
    return testsupport::summarize("PhraseMarkersTests");
}
