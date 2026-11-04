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
//  stream, and the timeline that maps the output to track time.
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
    runUntil(p.e, p.d, p.out, start + 1200);   // 200 into the third pass
    const size_t at = p.out.frames.size();
    const size_t phase = (at - start) % 500;
    CHECK(p.e.act(action(LoopAction::Exit, 2)), "left");
    runUntil(p.e, p.d, p.out, at + 8000);
    CHECK(straight(p.out, at, at + 8000, 4000.0 + static_cast<double>(phase)),
          "plays on from where it was, past the loop's end, without a break");
    CHECK(p.e.live() && !p.e.looping(), "caught up: passing through again");
    CHECK(matchesTimeline(p.e, p.out), "the timeline maps every frame");
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

void testAheadCap() {
    TEST_CASE("the decoder far ahead");
    Playing p;
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
    testCrossfade();
    testForeignSeek();
    testNewTrackLive();
    testNewTrackBehindLoop();
    testAheadCap();
    testEndOfStream();
    testTimelineMath();
    return testsupport::summarize("LoopEngineTests");
}
