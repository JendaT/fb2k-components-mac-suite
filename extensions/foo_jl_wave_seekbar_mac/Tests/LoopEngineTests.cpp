//
//  LoopEngineTests.cpp
//  foo_wave_seekbar_mac
//
//  The mixer's audio side: passing through, syncs (the view's seek, its
//  measurement, a track change), loops made from the history without a
//  seek, new lengths taking effect at once (wrapping into a shorter loop,
//  running on into a longer one), moves back into the history and forward
//  into the audio decoded ahead, jumps, leaving a loop, catching up with
//  the decoder, the crossfade, a new track behind a loop, the end of the
//  stream, and the timeline that maps the output to track time. Then the
//  reserve (decoded audio kept ahead while no change is expected): built
//  and held, around a hover, across a track change, a second after each
//  sync; requests turned down across a track change, and taken again once
//  past it while hovering; where a jump or a loop plays from (relative, in
//  phase, and a seek's own at its target).
//
//  The "track" is mono at 1000 Hz and each sample holds its own frame
//  number (track time x 1000), so the output shows exactly which frames
//  play in which order. Splices are hard (no crossfade) except in the
//  crossfade test.
//

#include "TestSupport.h"
#include "../src/Core/LoopEngine.h"

using namespace waveseek;

namespace {

using Engine = LoopEngine<double>;
using Block = Engine::Block;

constexpr unsigned kRate = 1000;

// Decodes from track frame `next` on, `size` frames a block
struct Decoder {
    int64_t next;
    size_t size = 64;
    unsigned rate = kRate;
    std::vector<double> block() {
        std::vector<double> b;
        for (size_t i = 0; i < size; ++i) b.push_back(static_cast<double>(next++));
        return b;
    }
};

// What went out, frame by frame
struct Output {
    std::vector<double> frames;
};

// One block through the engine, its output collected
void step(Engine &e, Decoder &d, Output &out, bool newTrack = false) {
    const std::vector<double> in = d.block();
    std::vector<Block> blocks;
    if (e.process(in.data(), in.size(), 1, d.rate, 0, newTrack, blocks)) {
        out.frames.insert(out.frames.end(), in.begin(), in.end());
    } else {
        for (const Block &b : blocks) out.frames.insert(out.frames.end(), b.samples.begin(), b.samples.end());
    }
}

void runUntil(Engine &e, Decoder &d, Output &out, size_t frames, int maxBlocks = 200000) {
    for (int i = 0; i < maxBlocks && out.frames.size() < frames; ++i) step(e, d, out);
}

// Every output frame is what the timeline says it plays
bool matchesTimeline(const Engine &e, const Output &out, size_t from = 0) {
    for (size_t i = from; i < out.frames.size(); ++i) {
        const double t = trackTimeAt(e.timeline(), (static_cast<double>(i) + 0.5) / kRate);
        if (std::fabs(t * kRate - (out.frames[i] + 0.5)) > 1e-6) {
            printf("  output frame %zu plays %.0f, the timeline says %.3f\n", i, out.frames[i], t * kRate - 0.5);
            return false;
        }
    }
    return true;
}

// Played straight on from `first` over [from, to)
bool straight(const Output &out, size_t from, size_t to, double first) {
    for (size_t i = from; i < to && i < out.frames.size(); ++i) {
        if (out.frames[i] != first + static_cast<double>(i - from)) {
            printf("  output frame %zu plays %.0f, expected %.0f\n", i, out.frames[i], first + static_cast<double>(i - from));
            return false;
        }
    }
    return to <= out.frames.size();
}

// A loop from `start` (frame), `length` frames, from output frame `from` on
bool looping(const Output &out, size_t from, size_t to, double start, size_t length, size_t phase = 0) {
    for (size_t i = from; i < to && i < out.frames.size(); ++i) {
        const double want = start + static_cast<double>((phase + i - from) % length);
        if (out.frames[i] != want) {
            printf("  output frame %zu plays %.0f, expected %.0f\n", i, out.frames[i], want);
            return false;
        }
    }
    return to <= out.frames.size();
}

// A seek to 2 s, synced by the view's measurement, then 3 s played live
struct Playing {
    Engine e;
    Decoder d{ 2000 };
    Output out;
    Playing(double played = 3.0) {
        e.setFadeSeconds(0.0);
        e.flush(nullptr);
        e.sync(e.epoch(), 2.0);
        runUntil(e, d, out, static_cast<size_t>(played * kRate));
    }
};

LoopAction loop(uint64_t id, double start, double end, double to = NAN) {
    LoopAction a;
    a.kind = LoopAction::Loop;
    a.id = id;
    a.start = start;
    a.end = end;
    a.to = to;
    return a;
}

LoopAction action(LoopAction::Kind kind, uint64_t id, double start = 0.0, double end = 0.0, double to = NAN) {
    LoopAction a;
    a.kind = kind;
    a.id = id;
    a.start = start;
    a.end = end;
    a.to = to;
    return a;
}

void testPassThrough() {
    TEST_CASE("passing through");
    Playing p;
    CHECK(p.e.live() && p.e.pristine(), "untouched");
    CHECK(straight(p.out, 0, p.out.frames.size(), 2000.0), "what comes in goes out");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps it from the sync");
    CHECK_NEAR(p.e.bufferedTo(), static_cast<double>(p.d.next) / kRate, 1e-9, "the history reaches the latest frame");

    Engine unsynced;
    unsynced.flush(nullptr);
    Decoder d{ 0 };
    Output out;
    step(unsynced, d, out);
    CHECK(!unsynced.act(loop(1, 0.0, 0.05, 0.0)) && unsynced.rejectedId() == 1, "unsynced: requests are turned down");
}

void testLoopFromHistory() {
    TEST_CASE("a loop from the history");
    Playing p;   // live up to frame ~5000
    const size_t at = p.out.frames.size();
    CHECK(p.e.act(loop(1, 4.5, 5.0, 4.5)), "made without a seek");
    runUntil(p.e, p.d, p.out, at + 3000);
    CHECK(looping(p.out, at, at + 3000, 4500.0, 500), "back to its start, then 4500..4999 again and again");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
    CHECK(p.e.aheadSeconds() > 0.0 && p.e.aheadSeconds() < 2.0, "the decoder runs ahead, slowly");
}

void testLoopAfterSeek() {
    TEST_CASE("a loop bound by the view's seek");
    Engine e;
    e.setFadeSeconds(0.0);
    LoopArm arm;
    arm.id = 9;
    arm.target = 2.0;
    arm.then = loop(3, 2.0, 2.5, 2.0);
    e.flush(&arm);
    CHECK(e.synced() && e.boundArmId() == 9, "the seek syncs it");
    Decoder d{ 2000 };
    Output out;
    runUntil(e, d, out, 2000);
    CHECK(looping(out, 0, 2000, 2000.0, 500), "and loops from the first frame");
    CHECK(matchesTimeline(e, out), "the timeline maps every frame");

    // A move's fallback: the seek to the loop's start, playing on from further in
    Engine m;
    m.setFadeSeconds(0.0);
    arm.then = loop(4, 2.0, 2.5, 2.3);
    m.flush(&arm);
    Decoder d2{ 2000 };
    Output o2;
    runUntil(m, d2, o2, 1000);
    CHECK(looping(o2, 0, 1000, 2000.0, 500, 300), "from 2300 once decoded, then the loop");
}

void testNarrower() {
    TEST_CASE("narrower at once");
    Playing p;
    p.e.act(loop(1, 4.0, 5.0, 4.0));   // 1000 frames
    const size_t start = p.out.frames.size();
    runUntil(p.e, p.d, p.out, start + 1700);   // second pass, 700 in
    const size_t at = p.out.frames.size();
    (void)start;
    const size_t phase = static_cast<size_t>(std::llround(p.e.playingFrom() * kRate)) - 4000;   // 0..1000
    CHECK(p.e.act(action(LoopAction::Resize, 2, 0.0, 4.3)), "300 frames");
    CHECK(phase % 300 != 0, "(the test wraps into it somewhere inside)");
    runUntil(p.e, p.d, p.out, at + 2000);
    CHECK(looping(p.out, at, at + 2000, 4000.0, 300, phase % 300),
          "the very next frame is inside the shorter loop, as far in as the beat went");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testWider() {
    TEST_CASE("wider at once");
    Playing p;
    p.e.act(loop(1, 4.0, 4.5, 4.0));   // 500 frames
    const size_t start = p.out.frames.size();
    runUntil(p.e, p.d, p.out, start + 1300);   // third pass, 300 in
    const size_t at = p.out.frames.size();
    (void)start;
    const size_t phase = static_cast<size_t>(std::llround(p.e.playingFrom() * kRate)) - 4000;   // 0..500
    CHECK(p.e.act(action(LoopAction::Resize, 2, 0.0, 5.0)), "twice as long");
    runUntil(p.e, p.d, p.out, at + 3000);
    CHECK(straight(p.out, at, at + (1000 - phase), 4000.0 + static_cast<double>(phase)),
          "plays on past the old end in this pass");
    CHECK(looping(p.out, at + (1000 - phase), at + 3000, 4000.0, 1000), "then the 1000-frame loop");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testMoveBack() {
    TEST_CASE("moving back into the history");
    Playing p;
    p.e.act(loop(1, 4.0, 4.5, 4.0));
    const size_t start = p.out.frames.size();
    runUntil(p.e, p.d, p.out, start + 1200);
    const size_t at = p.out.frames.size();
    const size_t phase = (at - start) % 500;
    CHECK(p.e.act(action(LoopAction::Move, 2, 3.0, 3.5)), "two loops back");
    runUntil(p.e, p.d, p.out, at + 2000);
    CHECK(looping(p.out, at, at + 2000, 3000.0, 500, phase), "the same place in the moved loop, no gap");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testMoveForward() {
    TEST_CASE("moving forward into the audio ahead");
    Playing p;
    p.e.act(loop(1, 4.0, 4.5, 4.0));
    const size_t start = p.out.frames.size();
    // Loop until the decoder is a second past the loop's end
    for (int i = 0; i < 100000 && p.e.bufferedTo() < 5.6; ++i) step(p.e, p.d, p.out);
    const size_t at = p.out.frames.size();
    const size_t phase = (at - start) % 500;
    CHECK(p.e.act(action(LoopAction::Move, 2, 5.0, 5.5)), "two loops on");
    runUntil(p.e, p.d, p.out, at + 2000);
    CHECK(looping(p.out, at, at + 2000, 5000.0, 500, phase), "the same place in the moved loop, no gap");
    CHECK(!p.e.act(action(LoopAction::Move, 3, 40.0, 40.5)) && p.e.rejectedId() == 3, "far beyond what is decoded: turned down");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testJump() {
    TEST_CASE("jumping");
    Playing p(4.0);   // live up to ~6000
    const size_t at = p.out.frames.size();
    CHECK(p.e.act(action(LoopAction::Jump, 1, 0.0, 0.0, 4.0)), "back into the history");
    CHECK(!p.e.act(action(LoopAction::Jump, 2, 0.0, 0.0, 9.0)) && p.e.rejectedId() == 2, "forward past the decoder: turned down");
    runUntil(p.e, p.d, p.out, at + 6000);
    CHECK(straight(p.out, at, at + 6000, 4000.0), "on from 4000 without a break, through to the live stream");
    CHECK(p.e.live(), "caught up: passing through again");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testExit() {
    TEST_CASE("leaving the loop");
    Playing p;
    p.e.act(loop(1, 4.0, 4.5, 4.0));
    const size_t start = p.out.frames.size();
    runUntil(p.e, p.d, p.out, start + 1200);
    const size_t at = p.out.frames.size();
    const double from = std::round(p.e.playingFrom() * kRate);   // where the next frame comes from
    CHECK(p.e.act(action(LoopAction::Exit, 2)), "left");
    runUntil(p.e, p.d, p.out, at + 8000);
    CHECK(straight(p.out, at, at + 8000, from),
          "plays on from where it was, past the loop's end, without a break");
    CHECK(p.e.live() && !p.e.looping(), "caught up: passing through again");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testLoopStaysSet() {
    TEST_CASE("the loop stays set");
    Playing p;   // live up to ~5000
    p.e.act(loop(1, 4.0, 4.5, 4.0));
    runUntil(p.e, p.d, p.out, p.out.frames.size() + 700);
    // Before it: plays up to it, then is caught and loops
    size_t at = p.out.frames.size();
    CHECK(p.e.act(action(LoopAction::Jump, 2, 0.0, 0.0, 3.5)), "a jump before the loop");
    runUntil(p.e, p.d, p.out, at + 2000);
    CHECK(straight(p.out, at, at + 500, 3500.0), "plays from there up to the loop");
    CHECK(looping(p.out, at + 500, at + 2000, 4000.0, 500), "then the loop catches it");
    CHECK(p.e.looping(), "still set");
    // Past it: plays on, the loop waits
    at = p.out.frames.size();
    CHECK(p.e.act(action(LoopAction::Jump, 3, 0.0, 0.0, 4.7)), "a jump past the loop");
    for (int i = 0; i < 100000 && p.e.bufferedTo() < 7.0; ++i) step(p.e, p.d, p.out);
    CHECK(straight(p.out, at, p.out.frames.size(), 4700.0), "plays on past it, no wrap");
    CHECK(p.e.looping(), "the loop is still set behind it");
    // Back into it: loops again
    at = p.out.frames.size();
    CHECK(p.e.act(action(LoopAction::Jump, 4, 0.0, 0.0, 4.2)), "a jump into the loop");
    runUntil(p.e, p.d, p.out, at + 1500);
    CHECK(looping(p.out, at, at + 1500, 4000.0, 500, 200), "loops from there");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testRelativeJump() {
    TEST_CASE("relative jumps");
    Playing p;   // live up to ~5000
    LoopAction back = action(LoopAction::Jump, 1);
    back.by = -1.0;
    const double from = std::round(p.e.playingFrom() * kRate);
    const size_t at = p.out.frames.size();
    CHECK(p.e.act(back), "a second back from what plays");
    runUntil(p.e, p.d, p.out, at + 500);
    CHECK(straight(p.out, at, at + 500, from - 1000.0), "from exactly a second back, however late taken");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testInPhaseJump() {
    TEST_CASE("jumps in phase");
    // 0.5 s beats from 0.1. Played 3.0 ends late in a beat (5.008, 0.82 of
    // it: the beat before the target is nearer), 3.2 early (5.2, 0.2).
    for (const double played : { 3.0, 3.2 }) {
        for (const double target : { 3.1, 3.3 }) {
            Playing p(played);
            const double from = std::round(p.e.playingFrom() * kRate);
            LoopAction a = action(LoopAction::Jump, 1, 0.0, 0.0, target);
            a.beat = 0.5;
            a.beatAnchor = 0.1;
            const size_t at = p.out.frames.size();
            CHECK(p.e.act(a), "a jump in phase");
            runUntil(p.e, p.d, p.out, at + 500);
            const double landed = p.out.frames[at];
            const double d = std::fabs(std::fmod(from - 100.0, 500.0) - std::fmod(landed - 100.0, 500.0));
            CHECK(std::min(d, 500.0 - d) <= 1.0, "at once, at the same place within the beat");
            CHECK(std::fabs(landed - target * kRate) <= 251.0, "at most half a beat from the target");
            CHECK(straight(p.out, at, at + 500, landed), "and on from there");
            CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
        }
    }
}

void testLoopKeepsPhase() {
    TEST_CASE("a loop made where playback is");
    Playing p;   // live up to ~5000
    const double from = std::round(p.e.playingFrom() * kRate);
    const size_t at = p.out.frames.size();
    LoopAction around = loop(1, 4.5, 5.5);
    around.keepPhase = true;
    CHECK(p.e.act(around), "a loop around what plays");
    runUntil(p.e, p.d, p.out, at + 2000);
    const size_t toEnd = static_cast<size_t>(5500.0 - from);
    CHECK(straight(p.out, at, at + toEnd, from), "plays on without a jump");
    CHECK(looping(p.out, at + toEnd, at + 2000, 4500.0, 1000), "and wraps at its end, on the beat");

    Playing q;
    const double from2 = std::round(q.e.playingFrom() * kRate);
    LoopAction behind = loop(2, 4.0, 4.5);
    behind.keepPhase = true;
    const size_t at2 = q.out.frames.size();
    CHECK(q.e.act(behind), "a loop already played past");
    runUntil(q.e, q.d, q.out, at2 + 1000);
    const size_t phase = static_cast<size_t>(from2 - 4000.0) % 500;
    CHECK(looping(q.out, at2, at2 + 1000, 4000.0, 500, phase), "goes into it as far as its length goes");
}

void testCrossfade() {
    TEST_CASE("crossfade");
    Engine e;   // 5 ms = 5 frames at 1000 Hz
    e.flush(nullptr);
    e.sync(e.epoch(), 2.0);
    Decoder d{ 2000 };
    Output out;
    runUntil(e, d, out, 3000);
    const size_t at = out.frames.size();
    const double old = out.frames.back() + 1.0;
    e.act(action(LoopAction::Jump, 1, 0.0, 0.0, 3.0));
    runUntil(e, d, out, at + 20);
    bool mixed = true;
    for (size_t i = 0; i < 5; ++i) {
        const double w = (static_cast<double>(i) + 0.5) / 5.0;
        const double want = (old + static_cast<double>(i)) * (1.0 - w) + (3000.0 + static_cast<double>(i)) * w;
        mixed &= std::fabs(out.frames[at + i] - want) < 1e-6;
    }
    CHECK(mixed, "the first 5 frames blend the old continuation into the new");
    CHECK(out.frames[at + 5] == 3005.0, "then the new audio alone");
}

void testForeignSeek() {
    TEST_CASE("a seek from elsewhere");
    Playing p;
    p.e.act(loop(1, 4.0, 4.5, 4.0));
    runUntil(p.e, p.d, p.out, p.out.frames.size() + 800);
    const uint64_t epoch = p.e.epoch();
    p.e.flush(nullptr);
    CHECK(p.e.epoch() == epoch + 1 && !p.e.synced() && !p.e.looping() && p.e.live(), "drops everything, unsynced");
    p.e.sync(epoch, 1.0);
    CHECK(!p.e.synced(), "a measurement for the old seek is ignored");
}

void testNewTrackLive() {
    TEST_CASE("a gapless track change");
    Playing p;
    Decoder next{ 0 };
    Output out;
    step(p.e, next, out, true);
    CHECK(p.e.synced() && p.e.live(), "in step: synced to the new track's start");
    runUntil(p.e, next, out, 1000);
    CHECK(p.e.act(action(LoopAction::Jump, 1, 0.0, 0.0, 0.2)), "the new track's history works");
    Output after;
    runUntil(p.e, next, after, 100);
    CHECK(after.frames.front() == 200.0, "from its own frame 200");
}

void testNewTrackBehindLoop() {
    TEST_CASE("a new track behind a loop");
    Playing p;
    p.e.act(loop(1, 4.0, 4.5, 4.0));
    runUntil(p.e, p.d, p.out, p.out.frames.size() + 1000);
    // The decoder reaches the next track (another rate) while looping
    Decoder next{ 0 };
    next.rate = 2000;
    for (int i = 0; i < 4; ++i) step(p.e, next, p.out, i == 0);
    const size_t at = p.out.frames.size();
    runUntil(p.e, next, p.out, at + 1000, 20);
    bool inLoop = p.out.frames.size() >= at + 1000;
    for (size_t i = at; inLoop && i < at + 1000; ++i) inLoop = p.out.frames[i] >= 4000.0 && p.out.frames[i] < 4500.0;
    CHECK(inLoop, "still looping the old track");
    p.e.act(action(LoopAction::Exit, 2));
    Output rest;
    for (int i = 0; i < 2000 && !p.e.live(); ++i) step(p.e, next, rest);
    CHECK(p.e.live() && p.e.synced(), "after the old track's audio and the new one's: live, synced to the new track");
    bool reaches = false;
    for (double v : rest.frames) reaches |= v == 0.0;
    CHECK(reaches, "the new track plays from its first frame");
}

void testResponsive() {
    TEST_CASE("responsive");
    Playing idle, quick;
    quick.e.setResponsive(true);
    idle.e.act(loop(1, 4.0, 4.5, 4.0));
    quick.e.act(loop(1, 4.0, 4.5, 4.0));
    // One block each: idle sends a second of loop, responsive barely more than the block
    Decoder d1{ idle.d.next }, d2{ quick.d.next };
    Output o1, o2;
    step(idle.e, d1, o1);
    step(quick.e, d2, o2);
    CHECK(o1.frames.size() >= 1000, "idle: a second of loop per block (the decoder held back)");
    CHECK(o2.frames.size() <= 64, "responsive: about a block (a change is heard after little more)");

    // Large blocks from the decoder: the responsive step stays short
    Decoder big{ quick.d.next + 64, 500 };
    Output o3;
    step(quick.e, big, o3);
    CHECK(o3.frames.size() <= 31, "a 500-frame block, 30 frames out");
}

void testStandby() {
    TEST_CASE("responsive without a change");
    Playing p;   // live
    p.e.setResponsive(true);
    const size_t at = p.out.frames.size();
    step(p.e, p.d, p.out);
    CHECK(!p.e.live() && p.out.frames.size() - at <= 30, "short steps from the buffer while a change may come");
    runUntil(p.e, p.d, p.out, at + 2000);
    CHECK(straight(p.out, at, at + 2000, p.out.frames[at]), "the same audio, nothing skipped or doubled");
    CHECK(p.out.frames[at] == p.out.frames[at - 1] + 1.0, "following on from what passed through");
    p.e.setResponsive(false);
    for (int i = 0; i < 10000 && !p.e.live(); ++i) step(p.e, p.d, p.out);
    CHECK(p.e.live(), "then catches up and passes through again");
    CHECK(straight(p.out, at, p.out.frames.size(), p.out.frames[at]), "still without a break");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testAheadCap() {
    TEST_CASE("the decoder far ahead");
    Playing p;
    p.e.setResponsive(true);   // the decoder runs ahead fastest
    p.e.act(loop(1, 4.0, 4.5, 4.0));
    for (int i = 0; i < 20000 && p.e.looping(); ++i) step(p.e, p.d, p.out);
    CHECK(!p.e.looping(), "past the limit the loop ends");
    CHECK(p.e.aheadSeconds() <= Engine::kMaxAheadSeconds + 1.0, "near the limit, not beyond");
}

void testEndOfStream() {
    TEST_CASE("end of the stream");
    Playing p;
    p.e.act(loop(1, 4.0, 4.5, 4.0));
    runUntil(p.e, p.d, p.out, p.out.frames.size() + 1700);
    std::vector<Block> blocks;
    p.e.endOfStream(blocks);
    for (const Block &b : blocks) p.out.frames.insert(p.out.frames.end(), b.samples.begin(), b.samples.end());
    CHECK(p.out.frames.back() == static_cast<double>(p.d.next - 1), "everything decoded played, up to the last frame");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testTimelineMath() {
    TEST_CASE("timeline");
    const std::vector<LoopSegment> t = { { 0.0, 2.0, 0.0, 0.0 }, { 1.0, 4.0, 0.5, 0.0 }, { 3.0, 4.2, 0.25, 0.1 },
                                         { 4.0, 4.25, 0.0, 0.0 } };
    CHECK_NEAR(trackTimeAt(t, 0.3), 2.3, 1e-12, "straight on");
    CHECK_NEAR(trackTimeAt(t, 1.7), 4.2, 1e-12, "looping");
    CHECK_NEAR(trackTimeAt(t, 3.2), 4.2 + 0.05, 1e-12, "a moved loop, 0.1 in at its start");
    CHECK_NEAR(trackTimeAt(t, 4.5), 4.75, 1e-12, "straight on after leaving");
    CHECK(std::isnan(trackTimeAt({}, 1.0)), "no timeline");
}

// The reserve tests use 100-frame (0.1 s) blocks and a 5 s reserve
constexpr size_t kBlock = 100;
constexpr double kReserve = 5.0;

// Steps until the engine plays from the buffer (the step that does so
// counts); the first step with `newTrack` set. `untouched`: pristine before
// every step.
int blocksLive(Engine &e, Decoder &d, Output &out, bool *untouched = nullptr, bool newTrack = false) {
    int n = 0;
    bool pristine = true;
    while (n < 100) {
        pristine &= e.pristine();
        step(e, d, out, newTrack && n == 0);
        ++n;
        if (!e.live()) break;
    }
    if (untouched) *untouched = pristine;
    return n;
}

void testReserveHeld() {
    TEST_CASE("the reserve");
    Playing p;   // synced, live for 3 s
    p.d.size = kBlock;
    p.e.setReserveSeconds(kReserve);
    const size_t at = p.out.frames.size();
    step(p.e, p.d, p.out);
    CHECK(!p.e.live() && !p.e.pristine() && p.out.frames.size() - at == kBlock / 2,
          "from the buffer at once (live long enough): half a block out per block in");
    int blocks = 1;
    for (; blocks < 1000 && p.e.aheadSeconds() < kReserve; ++blocks) step(p.e, p.d, p.out);
    CHECK(p.e.aheadSeconds() >= kReserve && blocks <= 101, "the decoder runs ahead at twice its pace up to 5 s");
    bool held = true, wasLive = false;
    for (int i = 0; i < 300; ++i) {   // 30 s
        step(p.e, p.d, p.out);
        held &= p.e.aheadSeconds() >= kReserve && p.e.aheadSeconds() < kReserve + 0.06;
        wasLive |= p.e.live();
    }
    CHECK(held && !wasLive, "then holds it: a block out per block in");
    CHECK(straight(p.out, 0, p.out.frames.size(), 2000.0), "the same audio throughout, nothing skipped or doubled");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");

    const double from = std::round(p.e.playingFrom() * kRate);
    LoopAction forward = action(LoopAction::Jump, 1);
    forward.by = 4.0;
    const size_t j = p.out.frames.size();
    CHECK(p.e.act(forward), "a jump 4 s forward is in the buffer: no seek");
    runUntil(p.e, p.d, p.out, j + 500);
    CHECK(straight(p.out, j, j + 500, from + 4000.0), "and lands exactly there");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testReserveAroundHover() {
    TEST_CASE("the reserve around a hover");
    Playing p;
    p.d.size = kBlock;
    p.e.setReserveSeconds(kReserve);
    p.e.setResponsive(true);
    double most = 0.0;
    for (int i = 0; i < 4000 && most < Engine::kResponsiveAheadSeconds - 0.2; ++i) {
        step(p.e, p.d, p.out);
        most = std::max(most, p.e.aheadSeconds());
    }
    CHECK(most >= Engine::kResponsiveAheadSeconds - 0.2, "hovering: the decoder runs up to 120 s ahead, as without one");
    p.e.setResponsive(false);
    const double ceiling = kReserve + Engine::kReserveSlackSeconds;
    double last = p.e.aheadSeconds();
    bool falling = true;
    int blocks = 0;
    for (; blocks < 3000 && p.e.aheadSeconds() > ceiling; ++blocks) {
        step(p.e, p.d, p.out);
        falling &= p.e.aheadSeconds() < last;
        last = p.e.aheadSeconds();
    }
    CHECK(falling && p.e.aheadSeconds() <= ceiling && blocks <= 1200,
          "released: it drains back towards the reserve, a block per block");
    bool held = true, wasLive = false;
    for (int i = 0; i < 300; ++i) {
        step(p.e, p.d, p.out);
        held &= p.e.aheadSeconds() >= kReserve && p.e.aheadSeconds() <= ceiling;
        wasLive |= p.e.live();
    }
    CHECK(held && !wasLive, "then holds within 5 s over it, never passing through");
    CHECK(straight(p.out, 0, p.out.frames.size(), 2000.0), "the same audio throughout, nothing skipped or doubled");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testReserveTrackChange() {
    TEST_CASE("a gapless track change with the reserve");
    Playing p;
    p.d.size = kBlock;
    p.e.setReserveSeconds(kReserve);
    for (int i = 0; i < 1000 && p.e.aheadSeconds() < kReserve; ++i) step(p.e, p.d, p.out);
    // The old track's audio still to play, then the new one's from frame 0
    const size_t oldLeft = static_cast<size_t>(p.d.next - std::llround(p.e.playingFrom() * kRate));
    const size_t change = p.out.frames.size() + oldLeft;
    Decoder next{ 0, kBlock };
    step(p.e, next, p.out, true);

    CHECK(!p.e.act(action(LoopAction::Jump, 1, 0.0, 0.0, 4.0)) && p.e.rejectedId() == 1,
          "across the change: a jump into the old track's history is turned down (the view seeks)");
    LoopAction back = action(LoopAction::Jump, 2);
    back.by = -1.0;
    CHECK(!p.e.act(back) && p.e.rejectedId() == 2, "a relative jump too");
    CHECK(!p.e.act(loop(3, 4.0, 4.5, 4.0)) && p.e.rejectedId() == 3, "and a loop");
    CHECK(p.e.act(action(LoopAction::Exit, 4)) && p.e.rejectedId() == 3, "leaving a loop still works");

    int blocks = 1;
    for (; blocks < 1000 && !p.e.live(); ++blocks) step(p.e, next, p.out);
    CHECK(p.e.live() && p.e.synced() && blocks <= static_cast<int>(oldLeft / kBlock) + 5,
          "it catches up at twice the decoder's pace, whatever the reserve: live on the new track, synced");
    CHECK(straight(p.out, 0, change, 2000.0), "the old track to its last decoded frame");
    CHECK(straight(p.out, change, p.out.frames.size(), 0.0), "then the new track from its first frame");
    bool ownSegment = false;
    for (const LoopSegment &s : p.e.timeline()) {
        ownSegment |= s.from == 0.0 && std::fabs(s.first * kRate - static_cast<double>(change)) < 1e-6;
    }
    CHECK(ownSegment && p.e.timeline().front().from == 2.0, "each track its own timeline segment");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");

    CHECK(blocksLive(p.e, next, p.out) == 11, "a second live on the new track (10 blocks), then from the buffer");
    for (int i = 0; i < 1000 && p.e.aheadSeconds() < kReserve; ++i) step(p.e, next, p.out);
    CHECK(p.e.aheadSeconds() >= kReserve && p.e.synced(), "and the reserve is built again");
    // Its history begins where the change was left (the audio sent across
    // it is not kept)
    const double target = std::ceil(p.e.bufferedFrom() * kRate) / kRate + 0.5;
    const size_t j = p.out.frames.size();
    CHECK(p.e.act(action(LoopAction::Jump, 5, 0.0, 0.0, target)), "the new track's history works");
    runUntil(p.e, next, p.out, j + 200);
    CHECK(straight(p.out, change, j, 0.0) && straight(p.out, j, j + 200, std::round(target * kRate)),
          "from the new track's own time");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

// Hovering (responsive) across a gapless change: the short steps would never
// empty the new track's audio waiting behind the old one's, so every request
// would seek; it catches up instead and takes requests again
void testResponsiveTrackChange() {
    TEST_CASE("a gapless track change while hovering");
    Playing p;
    p.d.size = kBlock;
    p.e.setResponsive(true);
    for (int i = 0; i < 50; ++i) step(p.e, p.d, p.out);
    CHECK(!p.e.live() && p.e.aheadSeconds() > 3.0, "(hovering: short steps from the buffer, the decoder ahead)");
    const size_t oldLeft = static_cast<size_t>(p.d.next - std::llround(p.e.playingFrom() * kRate));
    const size_t change = p.out.frames.size() + oldLeft;
    Decoder next{ 0, kBlock };
    step(p.e, next, p.out, true);
    CHECK(!p.e.act(action(LoopAction::Jump, 1, 0.0, 0.0, 4.0)) && p.e.rejectedId() == 1,
          "across the change: a request is turned down (the view seeks)");

    int blocks = 1;
    for (; blocks < 2000 && !p.e.live(); ++blocks) step(p.e, next, p.out);
    CHECK(p.e.live() && p.e.synced() && blocks <= static_cast<int>(oldLeft / kBlock) + 5,
          "it catches up at twice the decoder's pace while hovering: live on the new track, synced");
    CHECK(straight(p.out, 0, change, 2000.0), "the old track to its last decoded frame");
    CHECK(straight(p.out, change, p.out.frames.size(), 0.0), "then the new track from its first frame");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");

    // Still hovering: short steps on the new track, and requests taken
    const size_t at = p.out.frames.size();
    step(p.e, next, p.out);
    CHECK(!p.e.live() && p.out.frames.size() - at <= 30, "short steps from the buffer again");
    for (int i = 0; i < 20; ++i) step(p.e, next, p.out);
    LoopAction forward = action(LoopAction::Jump, 2);
    forward.by = 0.5;
    const double from = std::round(p.e.playingFrom() * kRate);
    const size_t j = p.out.frames.size();
    CHECK(p.e.act(forward) && p.e.rejectedId() == 1, "a jump half a second forward on the new track: taken, no seek");
    runUntil(p.e, next, p.out, j + 200);
    CHECK(straight(p.out, change, j, 0.0) && straight(p.out, j, j + 200, from + 500.0), "and lands exactly there");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testReserveWaitsForTheClock() {
    TEST_CASE("the reserve waits a second after each sync");
    Engine e;
    e.setFadeSeconds(0.0);
    e.setReserveSeconds(kReserve);
    e.flush(nullptr);
    Decoder d{ 2000, kBlock };
    Output out;
    for (int i = 0; i < 15; ++i) step(e, d, out);
    CHECK(e.live() && e.pristine() && !e.synced(), "unsynced: passes through");
    e.sync(e.epoch(), 2.0);
    bool untouched = false;
    CHECK(blocksLive(e, d, out, &untouched) == 11 && untouched,
          "the view's measurement: live and untouched for a second (10 blocks), then from the buffer");
    CHECK(!e.pristine(), "touched from then on (the view keeps its clock as measured)");
    CHECK(straight(out, 0, out.frames.size(), 2000.0), "without a break");

    LoopArm arm;
    arm.id = 7;
    arm.target = 30.0;
    e.flush(&arm);
    Decoder d2{ 30000, kBlock };
    Output o2;
    CHECK(blocksLive(e, d2, o2, &untouched) == 11 && untouched, "the view's own seek: likewise");

    // A gapless change while still live, half a second in: a second on the new track
    e.flush(&arm);
    Decoder d3{ 30000, kBlock };
    Output o3;
    for (int i = 0; i < 5; ++i) step(e, d3, o3);
    CHECK(e.live(), "(live half a second after the seek)");
    Decoder next{ 0, kBlock };
    CHECK(blocksLive(e, next, o3, nullptr, true) == 11 && e.synced(), "a new track: likewise");
    CHECK(straight(o3, 0, 500, 30000.0) && straight(o3, 500, o3.frames.size(), 0.0), "without a break");
}

void testNoReserve() {
    TEST_CASE("no reserve");
    Playing p(30.0);
    CHECK(p.e.live() && p.e.pristine() && p.e.aheadSeconds() == 0.0, "30 s after the sync: passing through, as before");
    p.d.size = kBlock;
    p.e.setReserveSeconds(kReserve);
    for (int i = 0; i < 50; ++i) step(p.e, p.d, p.out);
    CHECK(!p.e.live() && p.e.aheadSeconds() > 2.0, "(a reserve set: part built)");
    p.e.setReserveSeconds(0.0);
    for (int i = 0; i < 1000 && !p.e.live(); ++i) step(p.e, p.d, p.out);
    CHECK(p.e.live(), "cleared: catches up and passes through again");
    for (int i = 0; i < 50; ++i) step(p.e, p.d, p.out);
    CHECK(p.e.live() && p.e.aheadSeconds() == 0.0, "and stays so");
    CHECK(straight(p.out, 0, p.out.frames.size(), 2000.0), "without a break");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
}

void testSeekRequestAtTarget() {
    TEST_CASE("a request with a seek plays from its target");
    // Made against the audio before the seek: its `by` and beat are ignored
    for (int variant = 0; variant < 2; ++variant) {
        Engine e;
        e.setFadeSeconds(0.0);
        LoopArm arm;
        arm.id = 9;
        arm.target = 2.0;
        LoopAction then = loop(3, 2.0, 2.5, 2.3);
        if (variant == 0) {
            then.by = 1.0;
        } else {
            then.beat = 0.5;   // in phase from 2.0 this would be 2.5, past the loop
            then.beatAnchor = 0.1;
        }
        arm.then = then;
        e.flush(&arm);
        Decoder d{ 2000 };
        Output out;
        runUntil(e, d, out, 1000);
        CHECK(looping(out, 0, 1000, 2000.0, 500, 300),
              variant == 0 ? "a loop with `by`: from 2300 once decoded, then the loop"
                           : "a loop in phase: from 2300 once decoded, then the loop");
        CHECK(matchesTimeline(e, out), "the timeline maps every frame");
    }
    Engine e;
    e.setFadeSeconds(0.0);
    LoopArm arm;
    arm.id = 9;
    arm.target = 2.0;
    LoopAction jump = action(LoopAction::Jump, 3, 0.0, 0.0, 2.03);
    jump.by = 1.0;
    arm.then = jump;
    e.flush(&arm);
    Decoder d{ 2000 };
    Output out;
    runUntil(e, d, out, 300);
    CHECK(straight(out, 0, 300, 2030.0) && e.rejectedId() == 0, "a jump with `by`: from 2030, in the first block");
}

void testLoopTarget() {
    TEST_CASE("where a loop plays from");
    for (const bool withTo : { false, true }) {
        Playing p;   // live up to ~5000
        const double from = std::round(p.e.playingFrom() * kRate);
        LoopAction a = loop(1, 4.0, 5.5, withTo ? 4.2 : NAN);
        a.by = -0.5;
        const size_t at = p.out.frames.size();
        CHECK(p.e.act(a), "a loop half a second back from what plays");
        runUntil(p.e, p.d, p.out, at + 3000);
        const size_t toEnd = static_cast<size_t>(5500.0 - (from - 500.0));
        CHECK(straight(p.out, at, at + toEnd, from - 500.0),
              withTo ? "`by` first: from half a second back, not `to`" : "from half a second back, however late taken");
        CHECK(looping(p.out, at + toEnd, at + 3000, 4000.0, 1500), "then the loop");
        CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
    }
    // In phase: 0.5 s beats from 0.1; at 5.2 it plays 0.2 into a beat
    Playing q(3.2);
    const double from = std::round(q.e.playingFrom() * kRate);
    LoopAction b = loop(2, 4.6, 5.6, 4.8);
    b.beat = 0.5;
    b.beatAnchor = 0.1;
    const size_t at = q.out.frames.size();
    CHECK(q.e.act(b), "a loop in phase");
    runUntil(q.e, q.d, q.out, at + 2000);
    const double landed = q.out.frames[at];
    const double d = std::fabs(std::fmod(from - 100.0, 500.0) - std::fmod(landed - 100.0, 500.0));
    CHECK(std::min(d, 500.0 - d) <= 1.0 && landed != 4800.0, "at the same place within the beat as what plays");
    CHECK(std::fabs(landed - 4800.0) <= 251.0, "at most half a beat from `to`");
    const size_t toEnd = static_cast<size_t>(5600.0 - landed);
    CHECK(straight(q.out, at, at + toEnd, landed) && looping(q.out, at + toEnd, at + 2000, 4600.0, 1000),
          "on from there, then the loop");
    CHECK(matchesTimeline(q.e, q.out), "the timeline maps every frame");
}

} // namespace

int main() {
    testPassThrough();
    testLoopFromHistory();
    testLoopAfterSeek();
    testNarrower();
    testWider();
    testMoveBack();
    testMoveForward();
    testJump();
    testExit();
    testLoopStaysSet();
    testRelativeJump();
    testInPhaseJump();
    testLoopKeepsPhase();
    testCrossfade();
    testForeignSeek();
    testNewTrackLive();
    testNewTrackBehindLoop();
    testResponsive();
    testStandby();
    testAheadCap();
    testEndOfStream();
    testTimelineMath();
    testReserveHeld();
    testReserveAroundHover();
    testReserveTrackChange();
    testResponsiveTrackChange();
    testReserveWaitsForTheClock();
    testNoReserve();
    testSeekRequestAtTarget();
    testLoopTarget();
    return testsupport::summarize("LoopEngineTests");
}
