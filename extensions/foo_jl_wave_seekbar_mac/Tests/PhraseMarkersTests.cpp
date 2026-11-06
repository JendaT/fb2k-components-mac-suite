//
//  PhraseMarkersTests.cpp
//  foo_wave_seekbar_mac
//
//  Phrase markers from a beat grid: positions, states, offsets, the
//  re-anchor point, the phrase phase, thinning, following the grid
//  section by section, which sections fit their bars, and the trusted grid
//  (on 102's real grid too).
//

#include "TestSupport.h"
#include "Grid102Fixture.h"
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

// A sparse build-up: two of four grid beats played in every bar, both on
// the grid. A Beat This! grid counts only the beats it heard, a classic
// grid looks for all four.
void testSparseBeats() {
    TEST_CASE("sparse beats");
    PhraseGrid g = lockedGrid(8);
    for (jl_bar_stat &b : g.bars) b = jl_bar_stat{ 1, 2, static_cast<uint8_t>(2 * jl_pulse_unit / 4), 0 };
    g.summary.source = jl_beatgrid_source_beat_this;
    CHECK(phraseMarkers(g, 32)[0].state == jl_phrase_locked, "Beat This!: every beat heard is on the grid");
    g.summary.source = jl_beatgrid_source_classic;
    CHECK(phraseMarkers(g, 32)[0].state == jl_phrase_drifting, "classic: half the grid beats missing");

    // Heard but off: still not Locked
    g.summary.source = jl_beatgrid_source_beat_this;
    for (jl_bar_stat &b : g.bars) b = jl_bar_stat{ 1, 1, static_cast<uint8_t>(3 * jl_pulse_unit / 4), 0 };
    CHECK(phraseMarkers(g, 32)[0].state == jl_phrase_broken, "one of three heard beats matched");
}

// One 128 BPM section with bars `bars`, from a grid from `source`
PhraseGrid fitGrid(const std::vector<jl_bar_stat> &bars, uint8_t source = jl_beatgrid_source_classic) {
    PhraseGrid g;
    g.summary.bpm = 128.0;
    g.summary.source = source;
    jl_grid_section s{};
    s.bpm = 128.0;
    s.bar_count = static_cast<uint32_t>(bars.size());
    g.sections = { s };
    g.sectionBars = bars;
    return g;
}

std::vector<jl_bar_stat> barsOf(std::initializer_list<std::pair<size_t, jl_bar_stat>> runs) {
    std::vector<jl_bar_stat> out;
    for (const auto &run : runs) out.insert(out.end(), run.first, run.second);
    return out;
}

void testSectionFit() {
    TEST_CASE("section fit");
    const uint8_t beat = static_cast<uint8_t>(jl_pulse_unit);
    const jl_bar_stat on{ 0, 4, beat, 0 }, off{ 40, 4, beat, 0 };
    CHECK(sectionFits(fitGrid(barsOf({ { 8, on }, { 8, off } })), 0), "8 good bars of 16: fits");
    CHECK(!sectionFits(fitGrid(barsOf({ { 7, on }, { 7, off } })), 0), "7 good bars: too few");
    CHECK(!sectionFits(fitGrid(barsOf({ { 8, on }, { 9, off } })), 0), "8 good of 17: under half");

    // Bars without a beat, or with only off-beats, are not judged
    const jl_bar_stat quiet{ 60, 0, static_cast<uint8_t>(jl_phrase_no_pulse_level * jl_pulse_unit - 1), 0 };
    const jl_bar_stat offbeat{ 60, 0, beat, jl_bar_offbeat };
    const SectionFit sparse = sectionFit(fitGrid(barsOf({ { 8, on }, { 40, quiet }, { 10, offbeat } })), 0);
    CHECK(sparse.judged == 8 && sparse.good == 8 && sparse.fits(), "quiet and off-beat bars left out");
    const jl_bar_stat justBeat{ 0, 4, static_cast<uint8_t>(jl_phrase_no_pulse_level * jl_pulse_unit), 0 };
    CHECK(sectionFit(fitGrid(barsOf({ { 8, justBeat } })), 0).judged == 8, "the has-a-beat level is judged");

    CHECK(sectionFits(fitGrid(barsOf({ { 8, { -15, 4, beat, 0 } } })), 0), "15 ms off is good");
    CHECK(!sectionFits(fitGrid(barsOf({ { 8, { 16, 4, beat, 0 } } })), 0), "16 ms is not");
    CHECK(sectionFits(fitGrid(barsOf({ { 8, { 0, 3, beat, 0 } } })), 0), "classic: 3 of 4 beats matched is good");
    CHECK(!sectionFits(fitGrid(barsOf({ { 8, { 0, 2, beat, 0 } } })), 0), "2 of 4 is not");
    const jl_bar_stat twoHeard{ 0, 2, static_cast<uint8_t>(2 * jl_pulse_unit / 4), 0 };
    CHECK(sectionFits(fitGrid(barsOf({ { 8, twoHeard } }), jl_beatgrid_source_beat_this), 0),
          "Beat This!: both beats it heard matched");
    CHECK(!sectionFits(fitGrid(barsOf({ { 8, { 0, 2, beat, 0 } } }), jl_beatgrid_source_beat_this), 0),
          "2 of 4 heard is not");

    PhraseGrid missing = fitGrid(barsOf({ { 20, on } }));
    missing.sectionBars.resize(10);
    CHECK(sectionFit(missing, 0).judged == 0 && !sectionFits(missing, 0), "bars missing: nothing judged");
    CHECK(!sectionFits(missing, 3), "no such section");

    // 102: only the 139 BPM section fits
    const PhraseGrid g = grid102::grid();
    const size_t judged[] = { 4, 225, 19, 7, 10 }, good[] = { 2, 204, 4, 5, 4 };
    for (size_t k = 0; k < 5; ++k) {
        const SectionFit fit = sectionFit(g, k);
        CHECK(fit.judged == judged[k] && fit.good == good[k], "102: each section's good bars of those judged");
        CHECK(fit.fits() == (k == 1), "102: only section 1 (139 BPM) fits");
    }
}

// 120 BPM from 0.2 s, bars from beat 1, 32-beat phrases from bar 2; the
// master's bar i says i ms. Sections: 120 to 30.1 s (on the master's
// beats), 150 to 45 s and 125 to 70 s (both off their bars), 100 after.
PhraseGrid fourSections() {
    PhraseGrid g;
    g.summary.bpm = 120.0;
    g.summary.anchor_seconds = 0.2;
    g.summary.bar_phase = 1;
    g.summary.phrase_phase_bars = 2;
    g.summary.phrase_confidence = 0.5f;
    for (int i = 0; i < 40; ++i) g.bars.push_back({ static_cast<int8_t>(i), 4, static_cast<uint8_t>(jl_pulse_unit), 0 });
    auto section = [](double start, double bpm, int barPhase, uint32_t first, uint32_t count) {
        jl_grid_section s{};
        s.start_seconds = start;
        s.bpm = bpm;
        s.anchor_seconds = start > 0.0 ? start : 0.2;
        s.bar_phase = static_cast<int8_t>(barPhase);
        s.phrase_phase_bars = -1;
        s.first_bar = first;
        s.bar_count = count;
        return s;
    };
    g.sections = { section(0.0, 120.0, 1, 0, 15), section(30.1, 150.0, 0, 15, 9), section(45.0, 125.0, 0, 24, 13),
                   section(70.0, 100.0, 0, 37, 10) };
    const jl_bar_stat good{ 1, 4, static_cast<uint8_t>(jl_pulse_unit), 0 }, bad{ 50, 0, static_cast<uint8_t>(jl_pulse_unit), 0 };
    g.sectionBars = barsOf({ { 15, good }, { 22, bad }, { 10, good } });
    return g;
}

void testTrustedGrid() {
    TEST_CASE("trusted grid");
    const PhraseGrid g = fourSections();
    const PhraseGrid t = trustedGrid(g);
    CHECK(t.sections.size() == 3, "the two sections off their bars merge into one master section");
    if (t.sections.size() != 3) return;
    CHECK(t.sections[0].bpm == 120.0 && t.sections[0].first_bar == 0 && t.sections[0].bar_count == 15, "the first kept");
    const jl_grid_section &span = t.sections[1];
    CHECK(span.bpm == 120.0, "the master's tempo");
    CHECK_NEAR(span.start_seconds, 30.2, 1e-12, "from the master's beat nearest 30.1 s");
    CHECK_NEAR(span.anchor_seconds, 30.2, 1e-12, "its beat 0 there");
    // Beat 60 is 30.2 s; the master's bars start on beats 1 + 4i, so its
    // bar 0 is beat 61, the master's bar 15
    CHECK(span.bar_phase == 1, "bars on the master's");
    CHECK(span.first_bar == 15 && t.sectionBars[span.first_bar].offset_ms == 15, "its bars from the master's bar 15");
    CHECK(span.bar_count == 20, "up to the last starting before 70 s (the master's bar 34)");
    CHECK(span.phrase_phase_bars == 3 && span.phrase_confidence == 0.5f, "the master's phrase phase, in its bars");
    CHECK(t.sections[2].bpm == 100.0 && t.sections[2].first_bar == 35 && t.sections[2].bar_count == 10,
          "the last kept, its bars after the master's");
    CHECK(t.sectionBars.size() == 45 && t.sectionBars[35].offset_ms == 1, "with its own bars");

    // The master section's phrases are the master's own over its span
    std::vector<double> spanPhrases, masterPhrases;
    for (const PhraseMarker &m : phraseMarkers(t, 32, true)) {
        if (m.section == 1 && m.phrase >= 0) spanPhrases.push_back(m.seconds);
    }
    for (const PhraseMarker &m : phraseMarkers(g, 32, false)) {
        if (m.seconds >= 30.2 && m.seconds < 70.0) masterPhrases.push_back(m.seconds);
    }
    bool same = spanPhrases.size() == masterPhrases.size() && spanPhrases.size() == 3;
    for (size_t i = 0; same && i < spanPhrases.size(); ++i) same = std::fabs(spanPhrases[i] - masterPhrases[i]) < 1e-9;
    CHECK(same, "its phrases where the master's are");

    // Nothing fits: the master grid alone
    PhraseGrid none = fourSections();
    for (jl_bar_stat &b : none.sectionBars) b.offset_ms = 50;
    const PhraseGrid master = trustedGrid(none);
    CHECK(!master.hasSections(), "no section fits: the master grid");
    CHECK(master.sections.size() == 1 && master.sections[0].bar_count == 40, "one section with the master's bars");

    // Everything fits: as stored
    PhraseGrid all = fourSections();
    for (jl_bar_stat &b : all.sectionBars) b = jl_bar_stat{ 1, 4, static_cast<uint8_t>(jl_pulse_unit), 0 };
    const PhraseGrid kept = trustedGrid(all);
    bool asStored = kept.sections.size() == 4;
    for (size_t k = 0; asStored && k < 4; ++k) {
        asStored = kept.sections[k].bpm == all.sections[k].bpm && kept.sections[k].anchor_seconds == all.sections[k].anchor_seconds;
    }
    CHECK(asStored, "every section fits: the stored sections");

    const PhraseGrid one = lockedGrid(16);
    CHECK(trustedGrid(one).sections.empty() && trustedGrid(one).bars.size() == 16, "one grid: unchanged");
}

// 102: the master's beats where the sections don't fit, and phrase starts
// on them
void testTrusted102() {
    TEST_CASE("trusted grid on 102");
    const PhraseGrid stored = grid102::grid();
    const PhraseGrid t = trustedGrid(stored);
    const double a = stored.summary.anchor_seconds, beat = 60.0 / 139.0;
    CHECK(t.sections.size() == 3, "master, the 139 section, master");
    if (t.sections.size() != 3) return;
    CHECK(t.sections[0].bpm == 139.0 && t.sections[0].anchor_seconds == a && t.sections[0].bar_count == 61,
          "the intro: the master grid and its first 61 bars");
    CHECK(t.sections[1].bpm == 139.0, "the fitting section kept");
    CHECK_NEAR(t.sections[1].anchor_seconds, a + 244 * beat, 1e-9, "on the master's beat 244 (it was 0.025 ms off)");
    CHECK(t.sections[1].phrase_phase_bars == 6 && t.sections[1].bar_count == 270, "with its own phrase phase and bars");
    CHECK_NEAR(t.sections[2].start_seconds, a + 1322 * beat, 1e-9, "the master again from its beat nearest 570.76 s");
    CHECK(t.sections[2].bar_count == 56, "with the master's last 56 bars");

    const auto markers = phraseMarkers(t, 16, true);
    size_t intro = 0;
    bool onIntroPhrases = true, onMaster = true;
    for (const PhraseMarker &m : markers) {
        if (m.phrase < 0) continue;
        const double n = (m.seconds - a) / beat;
        onMaster &= std::fabs(n - std::round(n)) * beat < 1e-9;
        if (m.section != 0) continue;
        // From the master's bar 0 (its beat 1), every 16 beats
        onIntroPhrases &= std::fabs(m.seconds - (a + (1 + 16 * static_cast<double>(intro)) * beat)) < 1e-9;
        intro++;
    }
    CHECK(intro == 16, "16 phrase starts in the intro");
    CHECK(onIntroPhrases, "the intro's every 16 of the master's beats from its first bar");
    CHECK(onMaster, "every phrase start on a master beat");

    double storedWorst = 0.0;
    for (const PhraseMarker &m : phraseMarkers(stored, 16, true)) {
        if (m.section != 0) continue;
        const double n = (m.seconds - a) / beat;
        storedWorst = std::max(storedWorst, std::fabs(n - std::round(n)) * beat);
    }
    CHECK(storedWorst > 0.1, "the stored intro's phrase starts were off the master's beats");
}

int main() {
    testSparseBeats();
    testPositions();
    testStates();
    testPhrasePhase();
    testThinning();
    testEmpty();
    testSections();
    testSectionFit();
    testTrustedGrid();
    testTrusted102();
    return testsupport::summarize("PhraseMarkersTests");
}
