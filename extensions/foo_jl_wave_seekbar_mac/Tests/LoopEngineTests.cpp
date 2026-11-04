//
//  LoopEngineTests.cpp
//  foo_wave_seekbar_mac
//
//  The gapless loop: bound by the seek to its start, the first pass
//  recorded, repeated sample for sample, a new length, leaving the loop
//  without a break, the held audio draining, other seeks, a new track in
//  the held audio, the end of the stream, and the timeline that maps
//  output frames back to track time.
//
//  The "track" is mono at 1000 Hz and each sample holds its own frame
//  number, so the output shows exactly which frames play in which order.
//

#include "TestSupport.h"
#include "../src/Core/LoopEngine.h"

#include <string>

using namespace waveseek;

namespace {

using Engine = LoopEngine<double>;
using Block = Engine::Block;

constexpr unsigned kRate = 1000;

// Decodes the track from `frame` on, `size` frames a block
struct Decoder {
    uint64_t next;
    size_t size;
    unsigned rate = kRate;
    unsigned channels = 1;
    Block read() {
        Block b;
        b.channels = channels;
        b.rate = rate;
        for (size_t i = 0; i < size; ++i) {
            for (unsigned c = 0; c < channels; ++c) b.samples.push_back(static_cast<double>(next));
            ++next;
        }
        return b;
    }
};

// What came out, first channel, frame by frame
struct Output {
    std::vector<double> frames;
    void add(const std::vector<Block> &blocks) {
        for (const Block &b : blocks) {
            for (size_t i = 0; i < b.frames(); ++i) frames.push_back(b.samples[i * b.channels]);
        }
    }
};

// Feeds blocks until at least `frames` have come out (or `maxBlocks` went in)
void run(Engine &engine, Decoder &decoder, Output &out, size_t frames, int maxBlocks = 100000) {
    for (int i = 0; i < maxBlocks && out.frames.size() < frames; ++i) {
        std::vector<Block> blocks;
        engine.process(decoder.read(), blocks);
        out.add(blocks);
    }
}

// Every output frame is the track frame the timeline says it plays
bool matchesTimeline(const Engine &engine, const Output &out, double start) {
    for (size_t f = 0; f < out.frames.size(); ++f) {
        const double t = trackTimeAt(engine.timeline(), start, kRate, static_cast<double>(f));
        if (std::fabs(t * kRate - out.frames[f]) > 1e-6) {
            printf("  frame %zu plays %.0f, timeline says %.3f\n", f, out.frames[f], t * kRate);
            return false;
        }
    }
    return true;
}

// A loop of 500 frames from track frame 2000 (2 s), decoded 64 frames a block
struct Fixture {
    Engine engine;
    Decoder decoder{ 2000, 64 };
    Output out;
    Fixture(double length = 0.5) {
        engine.arm(7, 2.0, length);
        engine.flush();    // the seek to 2 s
    }
};

void testBindAndRepeat() {
    TEST_CASE("bind and repeat");
    Fixture f;
    CHECK(f.engine.boundId() == 7 && f.engine.phase() == Engine::Recording, "the seek binds the armed loop");
    run(f.engine, f.decoder, f.out, 3000);
    bool exact = f.out.frames.size() >= 3000;
    for (size_t i = 0; exact && i < 3000; ++i) exact = f.out.frames[i] == 2000.0 + static_cast<double>(i % 500);
    CHECK(exact, "frames 2000..2499 again and again, no gap, nothing doubled");
    CHECK(f.engine.phase() == Engine::Repeating, "repeating");
    CHECK(matchesTimeline(f.engine, f.out, 2.0), "the timeline maps every frame");
    // About a 64-frame block held per 1000-frame quantum
    CHECK(f.engine.heldSeconds() > 0.0 && f.engine.heldSeconds() < 0.4, "the decoder runs ahead only slowly");
}

void testExitPlaysOn() {
    TEST_CASE("leaving the loop");
    Fixture f;
    run(f.engine, f.decoder, f.out, 1200);
    f.engine.requestExit();
    run(f.engine, f.decoder, f.out, 6000);
    // Find where the loop was left: after a whole pass, 2500 follows 2499
    size_t left = 0;
    for (size_t i = 1; i < f.out.frames.size(); ++i) {
        if (f.out.frames[i] == 2500.0) {
            left = i;
            break;
        }
    }
    CHECK(left > 0 && left % 500 == 0, "left at the end of a pass");
    bool straight = left > 0;
    for (size_t i = left; straight && i < f.out.frames.size(); ++i) {
        straight = f.out.frames[i] == 2500.0 + static_cast<double>(i - left);
    }
    CHECK(straight, "then the track plays straight on from the loop's end, nothing skipped");
    CHECK(f.engine.phase() == Engine::Idle, "the held audio drained: passing through again");
    CHECK(matchesTimeline(f.engine, f.out, 2.0), "the timeline maps every frame");
}

void testExitDuringFirstPass() {
    TEST_CASE("leaving during the first pass");
    Fixture f;
    run(f.engine, f.decoder, f.out, 100);
    f.engine.requestExit();
    run(f.engine, f.decoder, f.out, 2000);
    bool straight = true;
    for (size_t i = 0; straight && i < 2000; ++i) straight = f.out.frames[i] == 2000.0 + static_cast<double>(i);
    CHECK(straight, "never repeats: the track plays on");
    CHECK(matchesTimeline(f.engine, f.out, 2.0), "the timeline maps every frame");
}

void testLonger() {
    TEST_CASE("longer");
    Fixture f;
    run(f.engine, f.decoder, f.out, 1200);   // repeating
    f.engine.setLength(1.0);                 // 1000 frames
    run(f.engine, f.decoder, f.out, 8000);
    // After the change the passes grow to 2000..2999, the new beats from
    // the held audio, still without a gap
    bool sawLong = false;
    for (size_t i = 0; i < f.out.frames.size(); ++i) sawLong |= f.out.frames[i] == 2999.0;
    CHECK(sawLong, "the new beats play");
    CHECK(matchesTimeline(f.engine, f.out, 2.0), "the timeline maps every frame");
    // The last whole passes are 1000 frames, 2000..2999 in order
    const size_t n = f.out.frames.size();
    size_t lastStart = 0;
    for (size_t i = n - 1; i > 0; --i) {
        if (f.out.frames[i] == 2000.0) {
            lastStart = i;
            break;
        }
    }
    bool pass = lastStart >= 1000;
    for (size_t i = 0; pass && i < 1000; ++i) pass = f.out.frames[lastStart - 1000 + i] == 2000.0 + static_cast<double>(i);
    CHECK(pass, "a whole 1000-frame pass in order");
}

void testShorter() {
    TEST_CASE("shorter");
    Fixture f(1.0);
    run(f.engine, f.decoder, f.out, 1700);   // second pass, around frame 700 of the loop
    f.engine.setLength(0.25);                // 250 frames: 700 wraps to 200
    const size_t at = f.out.frames.size();
    run(f.engine, f.decoder, f.out, 4000);
    CHECK(f.out.frames[at] == 2000.0 + static_cast<double>((at - 1000) % 1000 % 250),
          "playing past the new end wraps back into it");
    bool wraps = true;
    for (size_t i = at + 1; wraps && i < f.out.frames.size(); ++i) {
        const double prev = f.out.frames[i - 1], now = f.out.frames[i];
        wraps = now == prev + 1.0 || (prev == 2249.0 && now == 2000.0);
    }
    CHECK(wraps, "then 2000..2249 again and again");
    CHECK(matchesTimeline(f.engine, f.out, 2.0), "the timeline maps every frame");
}

void testShorterThenLeave() {
    TEST_CASE("shorter, then leaving");
    Fixture f(1.0);
    run(f.engine, f.decoder, f.out, 2300);   // repeating, 1000 recorded
    f.engine.setLength(0.25);
    run(f.engine, f.decoder, f.out, 2600);
    f.engine.requestExit();
    run(f.engine, f.decoder, f.out, 8000);
    size_t left = 0;
    for (size_t i = 2600; i < f.out.frames.size(); ++i) {
        if (f.out.frames[i] == 2250.0) {
            left = i;
            break;
        }
    }
    bool straight = left > 0;
    for (size_t i = left; straight && i < f.out.frames.size(); ++i) {
        straight = f.out.frames[i] == 2250.0 + static_cast<double>(i - left);
    }
    CHECK(straight, "plays on from the shorter loop's end through the rest of the recording and the held audio");
    CHECK(matchesTimeline(f.engine, f.out, 2.0), "the timeline maps every frame");
}

void testLengthBeforeFirstBlock() {
    TEST_CASE("a length before the first block");
    Fixture f;
    f.engine.setLength(0.25);
    run(f.engine, f.decoder, f.out, 1000);
    bool exact = true;
    for (size_t i = 0; exact && i < 1000; ++i) exact = f.out.frames[i] == 2000.0 + static_cast<double>(i % 250);
    CHECK(exact, "the loop records the new length");
}

void testOtherSeek() {
    TEST_CASE("another seek");
    Fixture f;
    run(f.engine, f.decoder, f.out, 1500);
    f.engine.flush();   // a seek from elsewhere, nothing armed
    CHECK(f.engine.phase() == Engine::Idle && f.engine.flushedAway(), "drops the loop, says so");
    Decoder elsewhere{ 9000, 64 };
    Output after;
    run(f.engine, elsewhere, after, 640);
    bool through = true;
    for (size_t i = 0; through && i < 640; ++i) through = after.frames[i] == 9000.0 + static_cast<double>(i);
    CHECK(through, "then passes the stream through");

    Engine idle;
    idle.flush();
    CHECK(!idle.flushedAway(), "a seek with no loop is just a seek");
}

void testRearm() {
    TEST_CASE("a new loop");
    Fixture f;
    run(f.engine, f.decoder, f.out, 1500);
    f.engine.arm(8, 5.0, 0.25);
    f.engine.flush();
    CHECK(f.engine.boundId() == 8 && !f.engine.flushedAway(), "the next seek binds the new one");
    Decoder at5{ 5000, 64 };
    Output out;
    run(f.engine, at5, out, 1000);
    bool exact = true;
    for (size_t i = 0; exact && i < 1000; ++i) exact = out.frames[i] == 5000.0 + static_cast<double>(i % 250);
    CHECK(exact, "and repeats it");
}

void testNewTrackInHeld() {
    TEST_CASE("a new track behind the loop");
    Engine engine;
    engine.arm(1, 2.0, 0.5);
    engine.flush();
    Decoder d{ 2000, 64 };
    Output out;
    run(engine, d, out, 1200);
    // The decoder reaches the next track: another rate
    Decoder next{ 0, 64 };
    next.rate = 48000;
    for (int i = 0; i < 3; ++i) {
        std::vector<Block> blocks;
        engine.process(next.read(), blocks);
        out.add(blocks);
    }
    engine.setLength(2.0);   // can grow only up to the old track's held audio
    run(engine, next, out, 9000, 300);
    CHECK(engine.phase() == Engine::Repeating, "still looping");
    bool loopOnly = true;
    for (size_t i = 1200; loopOnly && i < out.frames.size(); ++i) loopOnly = out.frames[i] >= 2000.0;
    CHECK(loopOnly, "the new track's audio never plays inside the loop");
    CHECK(matchesTimeline(engine, out, 2.0), "the timeline maps every frame");
}

void testEndOfStream() {
    TEST_CASE("end of the stream");
    Fixture f;
    run(f.engine, f.decoder, f.out, 1700);
    std::vector<Block> blocks;
    f.engine.endOfStream(blocks);
    f.out.add(blocks);
    CHECK(f.engine.phase() == Engine::Idle, "everything played");
    CHECK(f.out.frames.back() == static_cast<double>(f.decoder.next - 1), "up to the last decoded frame");
    CHECK(matchesTimeline(f.engine, f.out, 2.0), "the timeline maps every frame");
}

void testStereo() {
    TEST_CASE("stereo");
    Engine engine;
    engine.arm(1, 1.0, 0.1);
    engine.flush();
    Decoder d{ 1000, 30 };
    d.channels = 2;
    std::vector<double> right;
    for (int i = 0; i < 40; ++i) {
        std::vector<Block> blocks;
        engine.process(d.read(), blocks);
        for (const Block &b : blocks) {
            for (size_t k = 0; k < b.frames(); ++k) right.push_back(b.samples[k * 2 + 1]);
        }
    }
    bool exact = right.size() > 300;
    for (size_t i = 0; exact && i < 300; ++i) exact = right[i] == 1000.0 + static_cast<double>(i % 100);
    CHECK(exact, "both channels loop together");
}

void testTimelineMath() {
    TEST_CASE("timeline");
    std::vector<LoopSegment> t = { { 0, 500, 0, 0.0 }, { 1700, 250, 200, 0.0 }, { 2000, 0, 0, 2.25 } };
    CHECK_NEAR(trackTimeAt(t, 2.0, 1000.0, 10.0), 2.010, 1e-12, "the first pass");
    CHECK_NEAR(trackTimeAt(t, 2.0, 1000.0, 600.0), 2.100, 1e-12, "repeating");
    CHECK_NEAR(trackTimeAt(t, 2.0, 1000.0, 1700.0), 2.200, 1e-12, "a new length, 200 frames in");
    CHECK_NEAR(trackTimeAt(t, 2.0, 1000.0, 1760.0), 2.010, 1e-12, "wrapping at 250");
    CHECK_NEAR(trackTimeAt(t, 2.0, 1000.0, 2500.0), 2.75, 1e-12, "straight on after leaving");
    CHECK(std::isnan(trackTimeAt({}, 2.0, 1000.0, 5.0)), "no timeline");
}

} // namespace

int main() {
    testBindAndRepeat();
    testExitPlaysOn();
    testExitDuringFirstPass();
    testLonger();
    testShorter();
    testShorterThenLeave();
    testLengthBeforeFirstBlock();
    testOtherSeek();
    testRearm();
    testNewTrackInHeld();
    testEndOfStream();
    testStereo();
    testTimelineMath();
    return testsupport::summarize("LoopEngineTests");
}
