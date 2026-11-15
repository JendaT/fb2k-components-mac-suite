//
//  IntakeSlowVolumeGuardTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeSlowVolumeGuard: UUID extraction from mac-volume://
//  paths, the 20 ms policy, marking once per UUID, the reset on a mount
//  change, a stale generation ignored, and concurrent use. Synthetic UUIDs.
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

static void testMarking() {
    g_context = "marking";
    SlowVolumeGuard g;
    CHECK(!g.isSlow(kUuidA) && g.slowCount() == 0, "nothing slow at first");
    uint64_t gen = g.generation();
    CHECK(!g.noteCall(kUuidA, 5, gen), "a fast call marks nothing");
    CHECK(!g.isSlow(kUuidA), "still not slow");
    CHECK(g.noteCall(kUuidA, 45000, gen), "a 45 ms call marks the UUID (log once)");
    CHECK(g.isSlow(kUuidA), "now slow");
    CHECK(!g.isSlow(kUuidB), "another UUID is not affected");
    CHECK(!g.noteCall(kUuidA, 60000, gen), "a second slow call does not mark again (no second log line)");
    CHECK(g.noteCall(kUuidB, 25000, gen) && g.slowCount() == 2, "a second UUID is marked on its own");
    CHECK(!g.noteCall("", 99000, gen) && !g.isSlow(""), "an empty UUID is never marked");

    g.reset();
    CHECK(!g.isSlow(kUuidA) && !g.isSlow(kUuidB) && g.slowCount() == 0, "a mount change forgets every slow UUID");
    CHECK(!g.noteCall(kUuidA, 45000, gen), "a call that started before the reset does not mark");
    CHECK(!g.isSlow(kUuidA), "so the remounted volume stays usable");
    gen = g.generation();
    CHECK(g.noteCall(kUuidA, 45000, gen), "after the reset a slow call marks again (and logs again)");
}

static void testConcurrent() {
    g_context = "concurrent";
    SlowVolumeGuard g;
    std::atomic<int> marked{0};
    std::vector<std::thread> threads;
    for (int t = 0; t < 8; t++) {
        threads.emplace_back([&g, &marked, t] {
            for (int i = 0; i < 2000; i++) {
                const char *uuid = (i % 2) ? kUuidA : kUuidB;
                (void)g.isSlow(uuid);
                if (i == 1000 + t && g.noteCall(uuid, 30000, g.generation())) marked++;
            }
        });
    }
    for (std::thread &t : threads) t.join();
    CHECK(marked.load() >= 1 && marked.load() <= 2 && g.slowCount() == static_cast<size_t>(marked.load()),
          "each UUID is marked at most once across threads");
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
