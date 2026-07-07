//
//  ScrobbleRulesTests.cpp
//  foo_jl_scrobble_mac
//
//  Unit tests for ScrobbleRules (Last.fm eligibility predicates).
//  Compiled standalone (pure C++); gating phase of Scripts/build.sh.
//

#include "../src/Core/ScrobbleRules.h"

#include <cstdio>
#include <string>

static int g_failures = 0;
static int g_checks = 0;
static std::string g_context;

#define CHECK(cond, what)                                                        \
    do {                                                                         \
        g_checks++;                                                             \
        if (!(cond)) {                                                          \
            g_failures++;                                                       \
            printf("FAIL [%s] %s\n", g_context.c_str(), what);                  \
        }                                                                       \
    } while (0)

#define CHECK_EQ(got, want, what)                                                \
    do {                                                                         \
        g_checks++;                                                             \
        if ((got) != (want)) {                                                  \
            g_failures++;                                                       \
            printf("FAIL [%s] %s: got %f, expected %f\n", g_context.c_str(),    \
                   what, (double)(got), (double)(want));                        \
        }                                                                       \
    } while (0)

int main(void) {
    using namespace ScrobbleRules;

    // --- requiredPlaytime: 50% of duration capped at 4 minutes ---
    {
        g_context = "requiredPlaytime";
        CHECK_EQ(requiredPlaytime(30.0), 15.0, "30s track needs 15s");
        CHECK_EQ(requiredPlaytime(200.0), 100.0, "200s track needs 100s");
        CHECK_EQ(requiredPlaytime(480.0), 240.0, "480s track capped at 240s");
        CHECK_EQ(requiredPlaytime(10000.0), 240.0, "long track capped at 240s");
        CHECK_EQ(requiredPlaytime(479.9), 239.95, "just below cap uses 50%");
    }

    // --- isEligibleForScrobble: duration bounds + playtime threshold ---
    {
        g_context = "isEligibleForScrobble";
        CHECK(!isEligibleForScrobble(29.9, 29.9), "under 30s never eligible");
        CHECK(isEligibleForScrobble(30.0, 15.0), "30s track at exactly 50%");
        CHECK(!isEligibleForScrobble(30.0, 14.9), "30s track just under 50%");
        CHECK(isEligibleForScrobble(600.0, 240.0), "10min track at 4min cap");
        CHECK(!isEligibleForScrobble(600.0, 239.9), "10min track just under cap");
        CHECK(!isEligibleForScrobble(86400.1, 300.0), "over 24h never eligible");
        CHECK(isEligibleForScrobble(86400.0, 240.0), "exactly 24h eligible");
        CHECK(!isEligibleForScrobble(0.0, 100.0), "zero duration never eligible");
        CHECK(!isEligibleForScrobble(-1.0, 100.0), "negative duration never eligible");
        CHECK(canScrobble(600.0, 240.0), "canScrobble alias agrees");
    }

    // --- isEligibleForNowPlaying: 3 second threshold ---
    {
        g_context = "isEligibleForNowPlaying";
        CHECK(!isEligibleForNowPlaying(0.0), "not at 0s");
        CHECK(!isEligibleForNowPlaying(2.99), "not just under 3s");
        CHECK(isEligibleForNowPlaying(3.0), "at exactly 3s");
        CHECK(isEligibleForNowPlaying(100.0), "well past 3s");
    }

    // --- isTrackLongEnough ---
    {
        g_context = "isTrackLongEnough";
        CHECK(!isTrackLongEnough(29.9), "under 30s too short");
        CHECK(isTrackLongEnough(30.0), "exactly 30s ok");
        CHECK(isTrackLongEnough(86400.0), "exactly 24h ok");
        CHECK(!isTrackLongEnough(86400.1), "over 24h too long");
    }

    // --- isValidTimestamp with injected now (deterministic) ---
    {
        g_context = "isValidTimestamp";
        const int64_t now = 1751900000;  // fixed reference "now"
        CHECK(isValidTimestamp(now, now), "current time valid");
        CHECK(isValidTimestamp(now + 60, now), "60s future skew allowed");
        CHECK(!isValidTimestamp(now + 61, now), "61s future rejected");
        CHECK(isValidTimestamp(kLastFmEpoch, now), "Last.fm epoch valid");
        CHECK(!isValidTimestamp(kLastFmEpoch - 1, now), "before Last.fm epoch rejected");
        CHECK(!isValidTimestamp(0, now), "zero timestamp rejected");
        CHECK(!isValidTimestamp(-1, now), "negative timestamp rejected");

        // Wall-clock overload sanity: a recent-past timestamp is valid,
        // prehistoric and far-future are not.
        CHECK(!isValidTimestamp(kLastFmEpoch - 1), "wall-clock overload rejects pre-epoch");
    }

    printf("ScrobbleRulesTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
