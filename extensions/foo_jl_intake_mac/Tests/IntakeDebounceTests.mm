//
//  IntakeDebounceTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeDebounce with a fake clock: a lone event fires after
//  the quiet time, a burst collapses into one firing, a writer that never
//  pauses still fires at the cap, early timer firings re-arm, and the next
//  event after a firing opens a new window. No real-time waits.
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeDebounce.h"
#include "TestHarness.h"

#include <chrono>

using namespace intake;
using namespace std::chrono_literals;

using TP = DebounceWindow::TimePoint;

static TP at(std::chrono::milliseconds ms) {
    return TP() + std::chrono::duration_cast<DebounceWindow::Duration>(ms);
}

static void testSingleEvent() {
    g_context = "single-event";
    DebounceWindow w;  // production: 1 s quiet, 3 s cap
    CHECK(!w.pending(), "nothing pending at first");
    CHECK(!w.fire(at(5000ms)), "firing with nothing pending does nothing");
    CHECK(w.add(at(100ms)), "the first event opens a window");
    CHECK(w.pending(), "pending");
    CHECK(w.due() == at(1100ms), "due 1 s after the event");
    CHECK(!w.fire(at(1099ms)), "not due 1 ms early");
    CHECK(w.pending(), "still pending after an early firing");
    CHECK(w.fire(at(1100ms)), "due at 1 s");
    CHECK(!w.pending(), "the window closed");
    CHECK(!w.fire(at(1200ms)), "a second firing does nothing");
}

static void testBurst() {
    g_context = "burst";
    DebounceWindow w(1.0, 3.0);
    CHECK(w.add(at(0ms)), "the first event arms");
    CHECK(!w.add(at(300ms)) && !w.add(at(600ms)) && !w.add(at(900ms)), "later events do not arm again");
    CHECK(w.due() == at(1900ms), "due 1 s after the last event");
    CHECK(!w.fire(at(1000ms)), "the first timer (armed for 1 s) finds it not due");
    CHECK(w.due() == at(1900ms), "and re-arms for the new due time");
    CHECK(w.fire(at(1900ms)), "one firing for the whole burst");
    CHECK(w.add(at(2500ms)), "the next event after the firing opens a new window");
    CHECK(w.due() == at(3500ms), "a fresh window: 1 s after it");
}

static void testCap() {
    g_context = "cap";
    DebounceWindow w(1.0, 3.0);
    w.add(at(0ms));
    // An event every 500 ms would postpone a pure trailing debounce forever.
    for (int t = 500; t <= 2500; t += 500) w.add(at(std::chrono::milliseconds(t)));
    CHECK(w.due() == at(3000ms), "capped at 3 s after the first event");
    CHECK(!w.fire(at(2999ms)), "not before the cap");
    CHECK(w.fire(at(3000ms)), "fires at the cap");
    w.add(at(3100ms));
    CHECK(w.due() == at(4100ms), "events after the cap open a new window");
}

static void testOrderingAndReset() {
    g_context = "ordering-reset";
    DebounceWindow w(1.0, 3.0);
    w.add(at(1000ms));
    w.add(at(900ms));  // an out-of-order time point must not move the due time back
    CHECK(w.due() == at(2000ms), "an earlier time point does not shorten the window");
    w.reset();
    CHECK(!w.pending() && !w.fire(at(5000ms)), "reset closes the window without firing");
    DebounceWindow tight(1.0, 0.5);
    tight.add(at(0ms));
    CHECK(tight.due() == at(1000ms), "a cap below the quiet time is raised to it");
    DebounceWindow zero(0.0, 0.0);
    zero.add(at(10ms));
    CHECK(zero.fire(at(10ms)), "zero quiet fires at once");
}

int main(void) {
    @autoreleasepool {
        testSingleEvent();
        testBurst();
        testCap();
        testOrderingAndReset();
    }
    TEST_MAIN_END();
}
