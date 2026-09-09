//
//  RateLimiterTests.mm
//  foo_jl_biography_mac
//
//  Unit tests for BiographyRateLimiter token-bucket math, driven by an
//  injected fake clock so no real time passes. Gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/RateLimiter.h"

#include <string>

static int g_failures = 0;
static int g_checks = 0;
static std::string g_context;

#define CHECK(cond, what) do { \
    g_checks++; \
    if (!(cond)) { \
        g_failures++; \
        printf("FAIL [%s] %s\n", g_context.c_str(), what); \
    } \
} while (0)

#define CHECK_NEAR(actual, expected, what) do { \
    g_checks++; \
    double _a = (actual), _e = (expected); \
    if (fabs(_a - _e) > 0.0001) { \
        g_failures++; \
        printf("FAIL [%s] %s: got %f, want %f\n", g_context.c_str(), what, _a, _e); \
    } \
} while (0)

int main() {
    @autoreleasepool {
        __block double now = 1000.0;
        BiographyClockSource clock = ^double { return now; };

        // 1 token/sec, burst 5
        {
            g_context = "burst drain";
            BiographyRateLimiter *limiter =
                [[BiographyRateLimiter alloc] initWithTokensPerSecond:1.0 burstCapacity:5 clockSource:clock];

            CHECK_NEAR(limiter.availableTokens, 5.0, "starts full");
            for (int i = 0; i < 5; i++) {
                CHECK([limiter tryAcquire], "burst token acquired");
            }
            CHECK([limiter tryAcquire] == NO, "6th immediate acquire fails");
            CHECK_NEAR(limiter.waitTimeForNextToken, 1.0, "must wait a full second for next token");
        }

        {
            g_context = "refill rate";
            now = 2000.0;
            BiographyRateLimiter *limiter =
                [[BiographyRateLimiter alloc] initWithTokensPerSecond:2.0 burstCapacity:4 clockSource:clock];

            // Drain completely
            for (int i = 0; i < 4; i++) [limiter tryAcquire];
            CHECK([limiter tryAcquire] == NO, "drained");

            // 0.25s at 2 tokens/sec -> 0.5 tokens: still not enough
            now += 0.25;
            CHECK([limiter tryAcquire] == NO, "half token is not a token");
            CHECK_NEAR(limiter.waitTimeForNextToken, 0.25, "needs 0.5 more tokens at 2/s");

            // Another 0.25s -> a full token
            now += 0.25;
            CHECK([limiter tryAcquire], "token after 0.5s at 2/s");
            CHECK([limiter tryAcquire] == NO, "only one accrued");
        }

        {
            g_context = "cap at burst";
            now = 3000.0;
            BiographyRateLimiter *limiter =
                [[BiographyRateLimiter alloc] initWithTokensPerSecond:10.0 burstCapacity:3 clockSource:clock];

            [limiter tryAcquire];
            // A long idle period must not exceed burst capacity
            now += 3600.0;
            CHECK_NEAR(limiter.availableTokens, 3.0, "refill capped at burst capacity");
        }

        {
            g_context = "wait time when available";
            now = 4000.0;
            BiographyRateLimiter *limiter =
                [[BiographyRateLimiter alloc] initWithTokensPerSecond:1.0 burstCapacity:2 clockSource:clock];
            CHECK_NEAR(limiter.waitTimeForNextToken, 0.0, "no wait while tokens available");
        }

        {
            g_context = "clock does not go backwards";
            now = 5000.0;
            BiographyRateLimiter *limiter =
                [[BiographyRateLimiter alloc] initWithTokensPerSecond:1.0 burstCapacity:1 clockSource:clock];
            [limiter tryAcquire];
            now -= 100.0;  // clock anomaly
            CHECK([limiter tryAcquire] == NO, "negative elapsed adds no tokens");
            now += 101.0;  // net +1s from drain
            CHECK([limiter tryAcquire], "recovers after clock moves forward");
        }

        printf("%s: %d checks, %d failures\n",
               g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
