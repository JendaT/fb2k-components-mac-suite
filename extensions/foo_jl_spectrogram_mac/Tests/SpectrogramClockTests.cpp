//
//  SpectrogramClockTests.cpp
//  foo_jl_spectrogram_mac
//
//  Unit tests for the column clock: an even column count per frame from an
//  unevenly stepping stream time, coasting through gaps, and restarts.
//  Standalone: no SDK, no Xcode.
//

#include "TestHarness.h"
#include "../src/Core/SpectrogramClock.h"
#include <vector>

namespace {

const double kFrame = 1.0 / 60.0;
const double kHop = 1.0 / 120.0;   // 2 columns per frame

// Stream time as the core reports it: updated in uneven steps, and absent
// for three frames every two seconds (the stall seen in recordings).
struct SteppingStream {
    double reported = 0.0;
    bool at(int frame, double host, double& out) {
        if (frame % 120 >= 117) return false;
        if (frame % 3 == 0) reported = host + (frame % 7) * 0.002;  // 0..12 ms of jitter
        out = reported;
        return true;
    }
};

// Run `frames` frames from `startFrame`, rendering every due column.
// Returns the column count of each frame.
std::vector<int> run(SpectrogramClock& clock, SteppingStream& stream, int startFrame, int frames) {
    std::vector<int> counts;
    for (int f = startFrame; f < startFrame + frames; ++f) {
        const double host = f * kFrame;
        double t = 0.0;
        const bool have = stream.at(f, host, t);
        const int n = clock.due(host, have, t, kHop);
        for (int i = 0; i < n; ++i) clock.advance(kHop);
        counts.push_back(n);
    }
    return counts;
}

// Picture position each frame: rendered columns plus the sub-column phase.
// Its step per frame is what the eye sees as the scroll speed.
void testEvenMotion() {
    g_context = "even motion";
    for (double fps : {60.0, 72.0, 75.0, 120.0}) {
        SpectrogramClock clock;
        SteppingStream stream;
        const double frame = 1.0 / fps;
        long columns = 0;
        double previous = -1.0;
        int even = 0, frames = 0;
        for (int f = 0; f < (int)(fps * 12); ++f) {
            const double host = f * frame;
            double t = 0.0;
            const bool have = stream.at(f, host, t);
            const int n = clock.due(host, have, t, kHop);
            for (int i = 0; i < n; ++i) clock.advance(kHop);
            columns += n;
            const double position = columns + clock.phase(kHop);
            if (f > (int)fps * 2 && previous >= 0.0) {
                const double expected = 120.0 / fps;
                even += std::fabs((position - previous) - expected) < 0.25 ? 1 : 0;
                frames++;
            }
            previous = position;
        }
        g_context = "even motion " + std::to_string((int)fps) + " fps";
        CHECK(even >= frames * 95 / 100, "at least 95% of frames step within a quarter column of the mean");
    }
}

void testEvenPace() {
    g_context = "even pace";
    SpectrogramClock clock;
    SteppingStream stream;
    run(clock, stream, 0, 120);  // settle
    const std::vector<int> counts = run(clock, stream, 120, 600);

    int even = 0, total = 0, stalls = 0;
    for (int n : counts) {
        even += n == 2 ? 1 : 0;
        stalls += n == 0 ? 1 : 0;
        total += n;
    }
    CHECK(even >= (int)counts.size() * 95 / 100, "at least 95% of frames move exactly two columns");
    CHECK_EQ(stalls, 0, "no frame stands still through the stream's gaps");
    // Ten seconds at 120 columns per second, give or take one frame.
    CHECK(total >= 1198 && total <= 1202, "keeps up with the stream over time");
}

void testFollowsDrift() {
    g_context = "drift";
    // The stream runs 0.5% fast: the clock must follow it, not host time.
    SpectrogramClock clock;
    int total = 0;
    for (int f = 0; f < 60 * 60; ++f) {
        const double host = f * kFrame;
        const int n = clock.due(host, true, host * 1.005, kHop);
        for (int i = 0; i < n; ++i) clock.advance(kHop);
        if (f > 0) total += n;
    }
    // One minute of stream time (60.3 s) at 120 columns per second.
    CHECK(std::abs(total - (int)(60.3 * 120)) <= 20, "column count follows the stream's rate");
}

void testRestart() {
    g_context = "restart";
    SpectrogramClock clock;
    CHECK_EQ(clock.due(10.0, false, 0.0, kHop), 0, "no stream time yet: nothing due");
    CHECK_EQ(clock.due(10.0, true, 5.0, kHop), 0, "first stream time anchors");
    CHECK_FLOAT_EQ(clock.next(kHop), 5.0 - SpectrogramClock::kRenderDelay + kHop, "grid starts behind the stream time");

    int n = clock.due(10.0 + 0.1, true, 5.1, kHop);
    CHECK(n >= 11 && n <= 13, "about 100 ms of columns after 100 ms");
    for (int i = 0; i < n; ++i) clock.advance(kHop);

    // Seek: the stream time starts over near zero.
    CHECK_EQ(clock.due(10.2, true, 0.0, kHop), 0, "a jump back resets");
    CHECK_EQ(clock.due(10.2 + kFrame, true, kFrame, kHop), 0, "and re-anchors on the next frame");
    CHECK(clock.next(kHop) < 0.1, "grid continues from the new position");

    // Pause: the controller resets; resuming re-anchors without a burst.
    clock.reset();
    CHECK_EQ(clock.due(50.0, true, 3.0, kHop), 0, "re-anchors after a reset");
    n = clock.due(50.0 + kFrame, true, 3.0 + kFrame, kHop);
    CHECK(n >= 1 && n <= 3, "no catch-up burst for the paused time");
}

void testUnreadColumnsSkipped() {
    g_context = "unread columns";
    // The controller renders nothing for two seconds (reads fail), then
    // reads succeed again: the grid has kept within kMaxGap of the display
    // clock instead of staying at the start of the stretch.
    SpectrogramClock clock;
    clock.due(0.0, true, 0.0, kHop);
    for (int f = 1; f <= 120; ++f) clock.due(f * kFrame, true, f * kFrame, kHop);
    const int n = clock.due(121 * kFrame, true, 121 * kFrame, kHop);
    CHECK(n > 0 && n <= (int)(SpectrogramClock::kMaxGap / kHop) + 1, "at most kMaxGap of columns due");
    CHECK(clock.next(kHop) > 121 * kFrame - SpectrogramClock::kRenderDelay - SpectrogramClock::kMaxGap,
          "grid moved past the unread stretch");
}

} // namespace

int main() {
    testEvenPace();
    testEvenMotion();
    testFollowsDrift();
    testRestart();
    testUnreadColumnsSkipped();
    TEST_MAIN_END();
}
