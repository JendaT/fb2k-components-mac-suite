//
//  IntakeSlowVolumeGuardTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeSlowVolumeGuard: UUID extraction from mac-volume://
//  paths, the 20 ms policy, marking only after three slow calls in a row
//  (a fast call ends the streak, so one stall never marks), marking once per
//  UUID, the reset on a mount change or Refresh, a stale generation ignored,
//  and concurrent use. Synthetic UUIDs.
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeSlowVolumeGuard.h"
#include "TestHarness.h"

#include <atomic>
#include <thread>
#include <vector>

using namespace intake;

static const char *const kUuidA = "00000000-AAAA-4000-8000-000000000001";
static const char *const kUuidB = "00000000-BBBB-4000-8000-000000000002";

static void testUuid() {
    g_context = "uuid";
    CHECK(macVolumeUuid("mac-volume://00000000-AAAA-4000-8000-000000000001/income/a.wav") == kUuidA,
          "the UUID of a mac-volume path");
    CHECK(macVolumeUuid("MAC-VOLUME://00000000-AAAA-4000-8000-000000000001/x") == kUuidA, "the scheme ignores case");
    CHECK(macVolumeUuid("mac-volume://00000000-AAAA-4000-8000-000000000001") == kUuidA, "no path after the UUID");
    CHECK(macVolumeUuid("mac-volume:///income/a.wav").empty(), "an empty UUID");
    CHECK(macVolumeUuid("mac-volume://").empty() && macVolumeUuid("mac-volume:/").empty(), "too short");
    CHECK(macVolumeUuid("file:///Volumes/share/a.wav").empty() && macVolumeUuid("/Volumes/share/a.wav").empty() &&
              macVolumeUuid("tidal://track/1").empty(),
          "other schemes and native paths");
}

static void testPolicy() {
    g_context = "policy";
    CHECK(!isSlowNativePathCall(1) && !isSlowNativePathCall(700) && !isSlowNativePathCall(20000),
          "1 us, the 0.7 ms first call and exactly 20 ms are not slow");
    CHECK(isSlowNativePathCall(20001) && isSlowNativePathCall(30000000), "over 20 ms is slow");
}

// `count` slow calls on `uuid`; true when the last one marked it.
static bool slowCalls(SlowVolumeGuard &g, const char *uuid, int count, uint64_t gen) {
    bool marked = false;
    for (int i = 0; i < count; i++) marked = g.noteCall(uuid, 45000, gen);
    return marked;
}

static void testMarking() {
    g_context = "marking";
    SlowVolumeGuard g;
    CHECK(kSlowCallsToMark == 3, "three slow calls in a row mark a volume");
    CHECK(!g.isSlow(kUuidA) && g.slowCount() == 0, "nothing slow at first");
    uint64_t gen = g.generation();
    CHECK(!g.noteCall(kUuidA, 5, gen), "a fast call marks nothing");
    CHECK(!g.noteCall(kUuidA, 45000, gen) && !g.isSlow(kUuidA), "one 45 ms call (a stall) marks nothing");
    CHECK(!g.noteCall(kUuidA, 45000, gen) && !g.isSlow(kUuidA), "nor two");
    CHECK(g.noteCall(kUuidA, 45000, gen), "the third slow call in a row marks the UUID (log once)");
    CHECK(g.isSlow(kUuidA), "now slow");
    CHECK(!g.isSlow(kUuidB), "another UUID is not affected");
    CHECK(!g.noteCall(kUuidA, 60000, gen), "a later slow call does not mark again (no second log line)");
    CHECK(!g.noteCall(kUuidA, 5, gen) && g.isSlow(kUuidA), "a fast call does not unmark (only reset() does)");
    CHECK(slowCalls(g, kUuidB, 3, gen) && g.slowCount() == 2, "a second UUID is marked on its own");
    CHECK(!slowCalls(g, "", 5, gen) && !g.isSlow(""), "an empty UUID is never marked");

    g_context = "streak";
    g.reset();
    gen = g.generation();
    CHECK(!slowCalls(g, kUuidA, 2, gen), "two slow calls");
    CHECK(!g.noteCall(kUuidA, 3, gen), "then a fast one ends the streak");
    CHECK(!slowCalls(g, kUuidA, 2, gen) && !g.isSlow(kUuidA), "so two more do not mark");
    CHECK(!slowCalls(g, kUuidB, 2, gen), "B's streak is its own");
    CHECK(!g.noteCall(kUuidA, 3, gen), "A's fast call");
    CHECK(g.noteCall(kUuidB, 45000, gen) && !g.isSlow(kUuidA), "does not end B's streak");
    CHECK(slowCalls(g, kUuidA, 3, gen) && g.isSlow(kUuidA), "three in a row mark A");

    g_context = "reset";
    g.reset();
    CHECK(!g.isSlow(kUuidA) && !g.isSlow(kUuidB) && g.slowCount() == 0, "a mount change forgets every slow UUID");
    CHECK(!slowCalls(g, kUuidA, 3, gen), "calls that started before the reset do not count");
    CHECK(!g.isSlow(kUuidA), "so the remounted volume stays usable");
    gen = g.generation();
    CHECK(!slowCalls(g, kUuidA, 2, gen), "a streak");
    g.reset();
    gen = g.generation();
    CHECK(!slowCalls(g, kUuidA, 2, gen), "reset() also forgets streaks");
    CHECK(g.noteCall(kUuidA, 45000, gen), "after the reset three slow calls mark again (and log again)");
}

static void testConcurrent() {
    g_context = "concurrent";
    SlowVolumeGuard g;
    std::atomic<int> marked{0};
    std::vector<std::thread> threads;
    for (int t = 0; t < 8; t++) {
        threads.emplace_back([&g, &marked] {
            for (int i = 0; i < 2000; i++) {
                const char *uuid = (i % 2) ? kUuidA : kUuidB;
                (void)g.isSlow(uuid);
                // B is always slow, A slow from call 1000 on.
                const uint64_t micros = (uuid == kUuidB || i >= 1000) ? 30000 : 4;
                if (g.noteCall(uuid, micros, g.generation())) marked++;
            }
        });
    }
    for (std::thread &t : threads) t.join();
    CHECK(marked.load() == 2 && g.slowCount() == 2 && g.isSlow(kUuidA) && g.isSlow(kUuidB),
          "each UUID is marked exactly once across threads");
}

int main(void) {
    @autoreleasepool {
        testUuid();
        testPolicy();
        testMarking();
        testConcurrent();
    }
    TEST_MAIN_END();
}
