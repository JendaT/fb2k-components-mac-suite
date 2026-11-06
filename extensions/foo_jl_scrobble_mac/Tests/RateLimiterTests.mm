//
//  RateLimiterTests.mm
//  foo_jl_scrobble_mac
//
//  Unit tests for RateLimiter token bucket, using an injected fake clock.
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Services/RateLimiter.h"

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

#define CHECK_NEAR(got, want, what)                                              \
    do {                                                                         \
        g_checks++;                                                             \
        double _g = (got), _w = (want);                                         \
        if (fabs(_g - _w) > 1e-9) {                                             \
            g_failures++;                                                       \
            printf("FAIL [%s] %s: got %.12f, expected %.12f\n",                 \
                   g_context.c_str(), what, _g, _w);                            \
        }                                                                       \
    } while (0)

int main(void) {
    @autoreleasepool {

    __block double now = 1000.0;
    RateLimiterClock clock = ^{ return now; };

    // --- Starts full; drains one token per acquire ---
    {
        g_context = "burst-drain";
        RateLimiter *rl = [[RateLimiter alloc] initWithTokensPerSecond:1.0
                                                         burstCapacity:3
                                                                 clock:clock];
        CHECK_NEAR(rl.availableTokens, 3.0, "starts at capacity");
        CHECK([rl tryAcquire], "1st");
        CHECK([rl tryAcquire], "2nd");
        CHECK([rl tryAcquire], "3rd");
        CHECK(![rl tryAcquire], "4th denied when empty");
        CHECK_NEAR(rl.availableTokens, 0.0, "empty after burst");
    }

    // --- Refill: elapsed * rate, clamped to capacity ---
    {
        g_context = "refill";
        now = 1000.0;
        RateLimiter *rl = [[RateLimiter alloc] initWithTokensPerSecond:2.0
                                                         burstCapacity:4
                                                                 clock:clock];
        for (int i = 0; i < 4; i++) [rl tryAcquire];
        CHECK(![rl tryAcquire], "empty");

        now = 1000.25;  // 0.25s * 2/s = 0.5 tokens
        CHECK(![rl tryAcquire], "half a token is not enough");
        CHECK_NEAR(rl.availableTokens, 0.5, "partial refill visible");

        now = 1000.5;   // total 1.0 token
        CHECK([rl tryAcquire], "one full token acquired");
        CHECK(![rl tryAcquire], "and only one");

        now = 2000.0;   // huge gap: clamps to capacity, not 1999 tokens
        CHECK_NEAR(rl.availableTokens, 4.0, "clamped to burst capacity");
    }

    // --- waitTimeForNextToken ---
    {
        g_context = "waitTime";
        now = 1000.0;
        RateLimiter *rl = [[RateLimiter alloc] initWithTokensPerSecond:0.5
                                                         burstCapacity:1
                                                                 clock:clock];
        CHECK_NEAR(rl.waitTimeForNextToken, 0.0, "no wait when full");
        CHECK([rl tryAcquire], "drain");
        CHECK_NEAR(rl.waitTimeForNextToken, 2.0, "1 token at 0.5/s = 2s");

        now = 1001.0;
        CHECK_NEAR(rl.waitTimeForNextToken, 1.0, "halfway there");
        now = 1002.0;
        CHECK_NEAR(rl.waitTimeForNextToken, 0.0, "token ready");
        CHECK([rl tryAcquire], "acquire after wait");
    }

    // --- Clock going backwards must not mint or destroy tokens ---
    {
        g_context = "clock-backwards";
        now = 1000.0;
        RateLimiter *rl = [[RateLimiter alloc] initWithTokensPerSecond:1.0
                                                         burstCapacity:2
                                                                 clock:clock];
        [rl tryAcquire];
        now = 999.0;  // regression
        CHECK_NEAR(rl.availableTokens, 1.0, "no refill on negative elapsed");
        CHECK([rl tryAcquire], "remaining token still usable");
    }

    }  // autoreleasepool

    printf("RateLimiterTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
