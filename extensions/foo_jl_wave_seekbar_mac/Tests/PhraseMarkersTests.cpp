//
//  PhraseMarkersTests.cpp
//  foo_wave_seekbar_mac
//
//  Phrase markers from a beat grid: positions, states, offsets, the
//  re-anchor point, the phrase phase, thinning, and following the grid
//  section by section.
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

    // Bars start on the bar phase: bar 0 on beat 2
    g.summary.bar_phase = 2;
    CHECK_NEAR(phraseMarkers(g, 32)[0].seconds, 0.1 + 2 * 60.0 / 128.0, 1e-9, "the first phrase on beat 2");
    CHECK_NEAR(phraseMarkers(g, 32)[1].seconds, 0.1 + (2 + 32) * 60.0 / 128.0, 1e-9, "the next 32 beats later");
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

// A track whose grid changes at 60 s: 128 BPM, then 140 BPM. The master
// grid (128) runs on with the second half Broken on it; the sections hold
// both halves Locked, the second with its phrase count from bar 2.
PhraseGrid twoTempoGrid() {
    PhraseGrid g = lockedGrid(64);   // the master: 64 bars of 128 BPM over 120 s
    for (size_t b = 32; b < 64; ++b) g.bars[b] = { 60, 0, static_cast<uint8_t>(jl_pulse_unit), 0 };
    g.bars[32].flags |= jl_bar_region_start;
    jl_grid_section a = jl_master_section(g.summary, 32);
    jl_grid_section b{};
    b.start_seconds = 60.2;
    b.bpm = 140.0;
    b.anchor_seconds = 60.2;
    b.bar_phase = 1;                 // bars from beat 1
    b.phrase_phase_bars = 2;         // phrases from bar 2
    b.phrase_confidence = 0.6f;
    b.first_bar = 32;
    b.bar_count = 35;
    g.sections = { a, b };
    g.sectionBars.assign(67, jl_bar_stat{ 1, 4, static_cast<uint8_t>(jl_pulse_unit), 0 });
    return g;
}

void testSections() {
    TEST_CASE("sections");
    const PhraseGrid g = twoTempoGrid();
    CHECK(g.hasSections(), "two sections");

    const auto master = phraseMarkers(g, 32, false);
    CHECK(master.size() == 8, "not following: the master grid's 8 phrases");
    CHECK(master[4].state == jl_phrase_reanchor && master[5].state == jl_phrase_broken, "the second half off it");

    const auto m = phraseMarkers(g, 32, true);
    // Section 0: 32 bars of 128 BPM from 0.1 s, phrases on bars 0, 8, 16, 24
    // (all before 60.2 s); then the new grid's marker; then section 1 from
    // its bar 2 on beat 1: 35 bars, phrases on bars 2, 10, 18, 26, 34
    CHECK(m.size() == 4 + 1 + 5, "4 phrases, the new grid, 5 phrases");
    if (m.size() != 10) return;
    CHECK(m[4].phrase == -1 && m[4].section == 1, "a marker where the second section starts");
    CHECK(m[4].state == jl_phrase_reanchor, "drawn as a re-anchor");
    CHECK_NEAR(m[4].seconds, 60.2, 1e-9, "at its start");
    CHECK_NEAR(m[4].reanchorSeconds, 60.2, 1e-9, "the triangle there too");
    CHECK_NEAR(m[4].bpm, 140.0, 1e-9, "with its tempo for the readout");
    const double beat = 60.0 / 140.0;
    CHECK_NEAR(m[5].seconds, 60.2 + (1 + 2 * 4) * beat, 1e-9, "the section's phrases from its own bar and phrase phase");
    CHECK_NEAR(m[6].seconds - m[5].seconds, 32 * beat, 1e-9, "32 of its beats apart");
    CHECK(m[5].phrase == 0 && m[5].startBar == 2 && m[5].section == 1, "its phrase count restarts");
    bool locked = true;
    for (const auto &p : m) locked &= p.phrase < 0 || p.state == jl_phrase_locked;
    CHECK(locked, "every phrase Locked on its own grid");
    CHECK_NEAR(lockedPhraseShare(m), 1.0, 1e-12, "the new grid's marker is not a phrase");
    for (size_t i = 0; i < 4; ++i) CHECK(m[i].seconds < 60.2, "the first section's phrases stop where the second starts");

    CHECK_NEAR(densestBpm(g, true), 140.0, 1e-12, "thinning by the fastest section");
    CHECK_NEAR(densestBpm(g, false), 128.0, 1e-12, "or the master");

    CHECK_NEAR(gridAt(g, 30.0, true).bpm, 128.0, 1e-12, "the first section's grid before the change");
    CHECK_NEAR(gridAt(g, 90.0, true).bpm, 140.0, 1e-12, "the second's after it");
    CHECK_NEAR(gridAt(g, 90.0, true).anchorSeconds, 60.2, 1e-12, "with its beat 0");
    CHECK_NEAR(gridAt(g, 90.0, false).bpm, 128.0, 1e-12, "not following: the master");

    // One section is the master grid: drawn as before
    PhraseGrid one = lockedGrid(64);
    one.sections = { jl_master_section(one.summary, 64) };
    one.sectionBars = one.bars;
    CHECK(!one.hasSections(), "one section is no sections");
    CHECK(phraseMarkers(one, 32, true).size() == 8, "following a single grid: the master's markers");

    // A section whose bars are missing is skipped, not read past the end
    PhraseGrid bad = twoTempoGrid();
    bad.sectionBars.resize(40);
    const auto skipped = phraseMarkers(bad, 32, true);
    CHECK(skipped.size() == 4, "only the section whose bars are there");
}

int main() {
    testPositions();
    testStates();
    testPhrasePhase();
    testThinning();
    testEmpty();
    testSections();
    return testsupport::summarize("PhraseMarkersTests");
}
