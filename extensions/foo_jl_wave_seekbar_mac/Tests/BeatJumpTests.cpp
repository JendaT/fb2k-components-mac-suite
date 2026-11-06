//
//  BeatJumpTests.cpp
//  foo_wave_seekbar_mac
//
//  Beat jumps and loops on a beat grid: the beat list (master and section
//  by section), beat numbers, jumps that keep the place in the beat, the
//  nearest beat, loops from the beat behind the cursor, and the loop's
//  step at each position check; the trusted grid's beats (102's real grid,
//  a real tempo change) and gridAt agreeing with the beat list.
//

#include "TestSupport.h"
#include "Grid102Fixture.h"
#include "../src/Core/BeatJump.h"

using namespace waveseek;

namespace {

// 120 BPM (0.5 s beats) from 0.2 s
PhraseGrid grid120() {
    PhraseGrid g;
    g.summary.bpm = 120.0;
    g.summary.anchor_seconds = 0.2;
    return g;
}

// 120 BPM from 0.2 s, then from 30.1 s a new grid at 150 BPM (0.4 s beats)
PhraseGrid twoGrids() {
    PhraseGrid g = grid120();
    jl_grid_section a{};
    a.start_seconds = 0.0;
    a.bpm = 120.0;
    a.anchor_seconds = 0.2;
    jl_grid_section b{};
    b.start_seconds = 30.1;
    b.bpm = 150.0;
    b.anchor_seconds = 30.1;
    g.sections = { a, b };
    return g;
}

void testBeatList() {
    TEST_CASE("beat list");
    const auto beats = beatTimes(grid120(), 10.0, false);
    CHECK(beats.size() == 20, "0.2 .. 9.7 every 0.5 s");
    CHECK_NEAR(beats.front(), 0.2, 1e-12, "the first beat is the anchor");
    CHECK_NEAR(beats.back(), 9.7, 1e-9, "the last before the end");

    PhraseGrid late = grid120();
    late.summary.anchor_seconds = 5.2;
    const auto back = beatTimes(late, 10.0, false);
    CHECK_NEAR(back.front(), 0.2, 1e-9, "beats run back from a late anchor to the start");
    CHECK(back.size() == 20, "the same beats");

    CHECK(beatTimes(PhraseGrid{}, 10.0, false).empty(), "no tempo, no beats");
    CHECK(beatTimes(grid120(), 0.0, false).empty(), "no duration, no beats");
    PhraseGrid wild = grid120();
    wild.summary.bpm = 1e9;
    CHECK(beatTimes(wild, 10.0, false).empty(), "an absurd tempo is ignored");
}

void testSectionBeats() {
    TEST_CASE("section beats");
    const PhraseGrid g = twoGrids();
    const auto beats = beatTimes(g, 40.0, true);
    // Section 0: 0.2 .. 29.7 (29.7 is 0.4 s before 30.1, under half a beat
    // is 0.25 s, so it stays; 30.2 would be past the start); section 1:
    // 30.1 .. 39.7 every 0.4 s
    size_t firstOfB = 0;
    while (firstOfB < beats.size() && beats[firstOfB] < 30.0) ++firstOfB;
    CHECK(firstOfB == 60, "60 beats on the first grid");
    CHECK_NEAR(beats[firstOfB - 1], 29.7, 1e-9, "its last beat");
    CHECK_NEAR(beats[firstOfB], 30.1, 1e-9, "the new grid's first beat");
    CHECK_NEAR(beats[firstOfB + 1] - beats[firstOfB], 0.4, 1e-9, "at its own tempo");
    CHECK(beats.size() == 60 + 25, "25 beats on the new grid");
    bool ascending = true;
    for (size_t i = 1; i < beats.size(); ++i) ascending &= beats[i] > beats[i - 1] + 0.2;
    CHECK(ascending, "ascending, nothing doubled at the change");

    // A new grid starting a hair after an old beat: that beat is dropped
    PhraseGrid close = twoGrids();
    close.sections[1].start_seconds = 29.8;
    close.sections[1].anchor_seconds = 29.8;
    const auto c = beatTimes(close, 40.0, true);
    bool gap = true;
    for (size_t i = 1; i < c.size(); ++i) gap &= c[i] - c[i - 1] > 0.2;
    CHECK(gap, "no beat closer than half a beat to the new grid's first");

    CHECK(beatTimes(g, 40.0, false).size() == 80, "not following: the master grid throughout");
}

void testBeatNumbers() {
    TEST_CASE("beat numbers");
    const auto beats = beatTimes(grid120(), 10.0, false);
    CHECK_NEAR(beatPosition(beats, 0.2), 0.0, 1e-12, "on beat 0");
    CHECK_NEAR(beatPosition(beats, 1.45), 2.5, 1e-9, "half way through beat 2");
    CHECK_NEAR(beatPosition(beats, 0.0), -0.4, 1e-9, "before the first beat, by its interval");
    CHECK_NEAR(beatPosition(beats, 9.95), 19.5, 1e-9, "after the last, likewise");
    CHECK_NEAR(timeAtBeat(beats, 2.5), 1.45, 1e-9, "and back");
    CHECK_NEAR(timeAtBeat(beats, 25.0), 12.7, 1e-9, "past the last beat by its interval");
    CHECK(std::isnan(beatPosition({}, 1.0)), "no beats, no number");
    CHECK(std::isnan(beatPosition({ 1.0 }, 1.0)), "one beat is no interval");

    const auto two = beatTimes(twoGrids(), 40.0, true);
    CHECK_NEAR(timeAtBeat(two, beatPosition(two, 30.3)), 30.3, 1e-9, "round trip on the new grid");
}

void testJumps() {
    TEST_CASE("jumps");
    const auto beats = beatTimes(grid120(), 60.0, false);
    CHECK_NEAR(jumpTarget(beats, 10.33, 16, 60.0), 18.33, 1e-9, "16 beats on, the same place in the beat");
    CHECK_NEAR(jumpTarget(beats, 10.33, -4, 60.0), 8.33, 1e-9, "4 back");
    CHECK_NEAR(jumpTarget(beats, 3.0, -32, 60.0), 0.0, 1e-12, "back past the start stops at 0");
    CHECK(std::isnan(jumpTarget(beats, 50.0, 32, 60.0)), "on past the end: no jump");
    CHECK(std::isnan(jumpTarget({}, 5.0, 4, 60.0)), "no grid: no jump");

    // Across a new grid the count goes on in its beats
    const auto two = beatTimes(twoGrids(), 60.0, true);
    // 29.45 is half way through beat 58 (29.2..29.7); 4 beats on: 59.5 is
    // half way 29.7..30.1 = 29.9, 60 is 30.1, so 62.5 is 30.1 + 2.5 * 0.4
    CHECK_NEAR(jumpTarget(two, 29.45, 4, 60.0), 31.1, 1e-9, "the count crosses into the new grid's beats");
}

void testNearest() {
    TEST_CASE("nearest beat");
    const auto beats = beatTimes(grid120(), 10.0, false);
    CHECK_NEAR(nearestBeat(beats, 1.3), 1.2, 1e-9, "the one behind");
    CHECK_NEAR(nearestBeat(beats, 1.5), 1.7, 1e-9, "the one ahead");
    CHECK_NEAR(nearestBeat(beats, 0.0), 0.2, 1e-12, "before the first: the first");
    CHECK_NEAR(nearestBeat(beats, 99.0), 9.7, 1e-9, "after the last: the last");
    CHECK(std::isnan(nearestBeat({}, 1.0)), "no beats");
}

void testLoops() {
    TEST_CASE("loops");
    const auto beats = beatTimes(grid120(), 60.0, false);
    const BeatLoop loop = makeLoop(beats, 10.43, 8, 60.0);
    CHECK(loop.active(), "a loop");
    CHECK_NEAR(loop.start, 10.2, 1e-9, "from the beat behind the cursor");
    CHECK_NEAR(loop.end, 14.2, 1e-9, "8 beats long");
    CHECK(loop.firstBeat == 20 && loop.beats == 8, "beat 20, 8 beats");
    CHECK_NEAR(makeLoop(beats, 10.68, 4, 60.0).start, 10.7, 1e-9, "a beat a hair ahead counts as behind");
    CHECK_NEAR(makeLoop(beats, 0.05, 4, 60.0).start, 0.2, 1e-12, "before the first beat: from the first");
    CHECK(!makeLoop(beats, 58.0, 8, 60.0).active(), "no loop that would run into the end");
    CHECK(!makeLoop({}, 5.0, 8, 60.0).active(), "no grid, no loop");
    CHECK(loop.contains(10.2) && loop.contains(14.1) && !loop.contains(14.2), "start in, end out");

    const BeatLoop shorter = resizedLoop(beats, loop, 2, 60.0);
    CHECK_NEAR(shorter.start, 10.2, 1e-9, "resized: the same start");
    CHECK_NEAR(shorter.end, 11.2, 1e-9, "2 beats");
    CHECK_NEAR(wrappedIntoLoop(shorter, 13.0), 11.0, 1e-9, "a position past the new end wraps into it");

    const BeatLoop moved = movedLoop(beats, loop, 16, 60.0);
    CHECK_NEAR(moved.start, 18.2, 1e-9, "moved 16 beats");
    CHECK(moved.beats == 8, "still 8 beats");
    CHECK(!movedLoop(beats, loop, -40, 60.0).active(), "moved before the start: gone");
    CHECK(!movedLoop(beats, loop, 200, 60.0).active(), "moved past the end: gone");
}

void testPhraseCatch() {
    TEST_CASE("phrase starts catch the loop");
    const auto beats = beatTimes(grid120(), 60.0, false);
    const std::vector<double> phrases = { 0.2, 8.2, 16.2, 24.2 };   // every 16 beats from beat 0
    // 9.5 s is beat 18.6: two beats after the phrase at beat 16
    CHECK_NEAR(makeLoop(beats, 9.5, 16, 60.0, phrases).start, 8.2, 1e-9, "16 beats, two late: from the phrase");
    CHECK_NEAR(makeLoop(beats, 9.5, 8, 60.0, phrases).start, 8.2, 1e-9, "8 beats, two late: from the phrase");
    CHECK_NEAR(makeLoop(beats, 9.5, 4, 60.0, phrases).start, 9.2, 1e-9, "4 beats, two late: the beat behind");
    CHECK_NEAR(makeLoop(beats, 10.1, 16, 60.0, phrases).start, 8.2, 1e-9, "16 beats, four late: still the phrase");
    CHECK_NEAR(makeLoop(beats, 10.7, 16, 60.0, phrases).start, 10.7, 1e-9, "five late: the beat behind");
    // 7.9 s is beat 15.4: the phrase is the next beat
    CHECK_NEAR(makeLoop(beats, 7.9, 4, 60.0, phrases).start, 8.2, 1e-9, "a beat early: from the phrase, ahead");
    CHECK_NEAR(makeLoop(beats, 7.3, 16, 60.0, phrases).start, 7.2, 1e-9, "two early: the beat behind");
    CHECK_NEAR(makeLoop(beats, 9.5, 16, 60.0).start, 9.2, 1e-9, "without phrase starts: the beat behind");
}

void testLoopSteps() {
    TEST_CASE("loop steps");
    const auto beats = beatTimes(grid120(), 60.0, false);
    const BeatLoop loop = makeLoop(beats, 10.43, 8, 60.0);   // 10.2 .. 14.2
    CHECK(loopStep(loop, 12.0, 0.035, true).kind == LoopStep::None, "inside: nothing");
    const LoopStep soon = loopStep(loop, 14.18, 0.035, true);
    CHECK(soon.kind == LoopStep::Schedule, "the end within the next check: schedule");
    CHECK_NEAR(soon.value, 0.02, 1e-9, "for when it comes");
    const LoopStep late = loopStep(loop, 14.21, 0.035, true);
    CHECK(late.kind == LoopStep::Seek, "past the end: seek");
    CHECK_NEAR(late.value, 10.21, 1e-9, "as far into the loop as it overran");
    CHECK(loopStep(loop, 20.0, 0.035, true).kind == LoopStep::None, "moved well past it: plays on, the loop waits");
    CHECK(loopStep(loop, 5.0, 0.035, true).kind == LoopStep::None, "moved before it: plays into it");
    CHECK(loopStep(loop, 14.21, 0.035, false).kind == LoopStep::None, "past the end but not from inside: plays on");
    CHECK(loopStep(BeatLoop{}, 12.0, 0.035, true).kind == LoopStep::None, "no loop: nothing");
}

// The largest difference between two beat lists of the same length; NAN
// when the lengths differ
double largestDifference(const std::vector<double> &a, const std::vector<double> &b) {
    if (a.size() != b.size()) return NAN;
    double worst = 0.0;
    for (size_t i = 0; i < a.size(); ++i) worst = std::max(worst, std::fabs(a[i] - b[i]));
    return worst;
}

// Every beat of `beats` sits on a beat of the grid gridAt gives there
bool gridAtAgrees(const PhraseGrid &grid, const std::vector<double> &beats) {
    for (double b : beats) {
        const GridAt g = gridAt(grid, b, true);
        if (!(g.bpm > 0.0)) return false;
        const double period = 60.0 / g.bpm;
        const double n = (b - g.anchorSeconds) / period;
        if (std::fabs(n - std::round(n)) * period > 1e-9) return false;
    }
    return true;
}

// "102 Loud - 5 Billion Stars": the stored sections run 137, 139, 138, 124
// and 125 BPM; only 139 fits its bars, and it sits on the master's beats
void testTrusted102() {
    TEST_CASE("trusted beats on 102");
    const PhraseGrid stored = grid102::grid();
    const double duration = grid102::kDuration;
    const PhraseGrid trusted = trustedGrid(stored);
    const auto master = beatTimes(stored, duration, false);
    const auto beats = beatTimes(trusted, duration, true);
    CHECK(master.size() == 1547, "the master grid's 1547 beats");
    CHECK_NEAR(largestDifference(beats, master), 0.0, 1e-9, "following the trusted grid: the master's 139 grid end to end");
    CHECK(gridAtAgrees(trusted, beats), "gridAt places every beat of the list");
    bool master139 = true;
    for (double t = 0.0; t < duration; t += 0.5) master139 &= gridAt(trusted, t, true).bpm == 139.0;
    CHECK(master139, "gridAt: 139 BPM throughout");

    const double beat = 60.0 / 139.0;
    CHECK_NEAR(jumpTarget(beats, 30.0, 16, duration) - 30.0, 16 * beat, 1e-9, "16 beats in the intro are 139 BPM beats");
    CHECK_NEAR(jumpTarget(beats, 600.0, -16, duration) - 600.0, -16 * beat, 1e-9, "and at 600 s");
    CHECK_NEAR(jumpTarget(beats, 650.0, 4, duration) - 650.0, 4 * beat, 1e-9, "and in the outro");

    // What the stored sections gave: 6.3 ms a beat off in the intro, 3.1 ms at 600 s
    const auto followed = beatTimes(stored, duration, true);
    CHECK_NEAR(jumpTarget(followed, 30.0, 16, duration) - 30.0, 16 * 60.0 / 137.0, 1e-9, "the stored intro: 137 BPM");
    CHECK_NEAR(jumpTarget(followed, 600.0, -16, duration) - 600.0, -16 * 60.0 / 138.0, 1e-9, "570-624 s: 138 BPM");
}

// A real tempo change, with its bars on both sides good: still followed
PhraseGrid measuredTwoGrids(jl_bar_stat secondBars) {
    PhraseGrid g = twoGrids();               // 120 BPM, then 150 from 30.1 s
    g.sections[0].bar_count = 15;            // 0.2 .. 30.2 in 2 s bars
    g.sections[1].first_bar = 15;
    g.sections[1].bar_count = 19;            // 30.1 .. 60.5 in 1.6 s bars
    g.sectionBars.assign(15, jl_bar_stat{ 1, 4, static_cast<uint8_t>(jl_pulse_unit), 0 });
    g.sectionBars.insert(g.sectionBars.end(), 19, secondBars);
    return g;
}

void testTrustedTempoChange() {
    TEST_CASE("trusted beats follow a real change");
    const PhraseGrid good = measuredTwoGrids(jl_bar_stat{ -2, 4, static_cast<uint8_t>(jl_pulse_unit), 0 });
    const PhraseGrid trusted = trustedGrid(good);
    CHECK(trusted.sections.size() == 2, "both sections kept");
    const auto beats = beatTimes(trusted, 60.0, true);
    CHECK_NEAR(largestDifference(beats, beatTimes(good, 60.0, true)), 0.0, 1e-12, "the same beats as the stored sections");
    CHECK_NEAR(jumpTarget(beats, 40.0, 4, 60.0) - 40.0, 1.6, 1e-9, "after the change, 150 BPM beats");
    CHECK_NEAR(jumpTarget(beats, 10.0, 4, 60.0) - 10.0, 2.0, 1e-9, "before it, 120 BPM beats");
    CHECK(gridAtAgrees(trusted, beats), "gridAt places every beat of the list");
    CHECK_NEAR(gridAt(trusted, 40.0, true).bpm, 150.0, 1e-12, "gridAt after the change: the new tempo");

    // The same change with the new grid's bars 40 ms off: the master runs on
    const PhraseGrid off = measuredTwoGrids(jl_bar_stat{ 40, 1, static_cast<uint8_t>(jl_pulse_unit), 0 });
    const PhraseGrid master = trustedGrid(off);
    CHECK(master.sections.size() == 2 && master.sections[1].bpm == 120.0, "the master grid over the new grid's span");
    CHECK_NEAR(master.sections.size() == 2 ? master.sections[1].start_seconds : NAN, 30.2, 1e-9,
               "from its beat nearest the new grid's start");
    CHECK_NEAR(largestDifference(beatTimes(master, 60.0, true), beatTimes(off, 60.0, false)), 0.0, 1e-9,
               "its beats throughout");
    CHECK_NEAR(gridAt(master, 40.0, true).bpm, 120.0, 1e-12, "gridAt: the master's tempo");
}

// A new grid's beat 0 a little before its start: gridAt switches there, as
// the beat list does
void testGridAtSwitch() {
    TEST_CASE("gridAt switches with the beat list");
    PhraseGrid g = twoGrids();
    g.sections[1].start_seconds = 30.12;     // its beat 0 at 30.1, 20 ms before
    const auto beats = beatTimes(g, 40.0, true);
    CHECK(gridAtAgrees(g, beats), "every beat on the grid gridAt gives there");
    CHECK_NEAR(gridAt(g, 30.105, true).bpm, 150.0, 1e-12, "from the new grid's first beat");
    CHECK_NEAR(gridAt(g, 30.09, true).bpm, 120.0, 1e-12, "the old grid before it");
}

} // namespace

int main() {
    testBeatList();
    testSectionBeats();
    testBeatNumbers();
    testJumps();
    testNearest();
    testLoops();
    testPhraseCatch();
    testLoopSteps();
    testTrusted102();
    testTrustedTempoChange();
    testGridAtSwitch();
    return testsupport::summarize("BeatJumpTests");
}
