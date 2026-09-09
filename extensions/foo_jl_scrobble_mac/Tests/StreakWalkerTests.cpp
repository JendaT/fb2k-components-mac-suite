//
//  StreakWalkerTests.cpp
//  foo_jl_scrobble_mac
//
//  Unit tests for the StreakWalker streak-discovery state machine.
//  Compiled standalone (pure C++); gating phase of Scripts/build.sh.
//

#include "../src/Core/StreakWalker.h"

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

using scrobble::StreakWalker;
using Action = scrobble::StreakWalker::Action;

int main(void) {
    // --- Scrobbled today, 5-day streak, then a gap ---
    {
        g_context = "streak-with-today";
        StreakWalker w;
        CHECK(w.begin(true) == Action::CheckDay, "begin asks for a check");
        CHECK(w.currentStreak() == 1, "today counts as day one");
        CHECK(w.daysChecked() == 1, "today already examined");
        CHECK(w.daysBack() == 1, "first check is yesterday");

        // Days 1-4 back all have scrobbles
        for (long day = 1; day <= 4; day++) {
            CHECK(w.daysBack() == day, "walks one day at a time");
            CHECK(w.onDayResult(true) == Action::CheckDay, "confirmed day continues walk");
        }
        CHECK(w.currentStreak() == 5, "today + 4 confirmed days");

        CHECK(w.daysBack() == 5, "next check is day 5 back");
        CHECK(w.onDayResult(false) == Action::GapFound, "gap ends the walk");
        CHECK(w.currentStreak() == 5, "gap day does not count");
        CHECK(w.daysChecked() == 6, "all six examined days counted");
    }

    // --- Not scrobbled today: yesterday counted exactly once ---
    // (regression: the pre-extraction traversal checked yesterday twice
    //  in this path, inflating the streak by one)
    {
        g_context = "no-scrobble-today";
        StreakWalker w;
        w.begin(false);
        CHECK(w.currentStreak() == 0, "no streak credit for today");
        CHECK(w.daysBack() == 1, "first check is yesterday");

        CHECK(w.onDayResult(true) == Action::CheckDay, "yesterday confirmed");
        CHECK(w.currentStreak() == 1, "streak is exactly one");
        CHECK(w.daysBack() == 2, "next check is TWO days back, not yesterday again");

        CHECK(w.onDayResult(false) == Action::GapFound, "gap two days back");
        CHECK(w.currentStreak() == 1, "single-day streak preserved");
    }

    // --- Immediate gap: no streak at all ---
    {
        g_context = "no-streak";
        StreakWalker w;
        w.begin(false);
        CHECK(w.onDayResult(false) == Action::GapFound, "yesterday empty ends immediately");
        CHECK(w.currentStreak() == 0, "zero streak");

        w.begin(true);
        CHECK(w.onDayResult(false) == Action::GapFound, "today-only streak");
        CHECK(w.currentStreak() == 1, "today alone is a 1-day streak");
    }

    // --- Errors: retry twice with 2s/4s backoff, third failure exhausts ---
    {
        g_context = "retries";
        StreakWalker w;
        w.begin(true);

        CHECK(w.onDayError() == Action::Retry, "first error retries");
        CHECK(w.retryDelay() == 2.0, "first backoff 2s");
        CHECK(w.daysBack() == 1, "same day retried");

        CHECK(w.onDayError() == Action::Retry, "second error retries");
        CHECK(w.retryDelay() == 4.0, "second backoff 4s");

        CHECK(w.onDayError() == Action::Exhausted, "third error gives up");
        CHECK(w.currentStreak() == 1, "partial result preserved");
    }

    // --- Error followed by success resets the retry counter ---
    {
        g_context = "retry-reset";
        StreakWalker w;
        w.begin(true);

        w.onDayError();
        w.onDayError();
        CHECK(w.onDayResult(true) == Action::CheckDay, "success after retries continues");
        CHECK(w.currentStreak() == 2, "confirmed day counted");

        // Fresh error budget for the next day
        CHECK(w.onDayError() == Action::Retry, "counter was reset");
        CHECK(w.retryDelay() == 2.0, "backoff starts over at 2s");
    }

    // --- begin() fully resets a reused walker ---
    {
        g_context = "reuse";
        StreakWalker w;
        w.begin(true);
        for (int i = 0; i < 10; i++) w.onDayResult(true);
        w.onDayError();

        w.begin(false);
        CHECK(w.currentStreak() == 0, "streak reset");
        CHECK(w.daysChecked() == 0, "days reset");
        CHECK(w.daysBack() == 1, "walk restarts at yesterday");
        CHECK(w.onDayError() == Action::Retry, "retry budget reset");
        CHECK(w.retryDelay() == 2.0, "backoff reset");
    }

    printf("StreakWalkerTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
