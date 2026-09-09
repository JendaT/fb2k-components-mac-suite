//
//  QueueFormattingTests.cpp
//  foo_jl_queue_manager
//
//  Unit tests for QueueFormatting (duration and status bar text).
//  Pure C++, compiled standalone; run as a gating phase by Scripts/build.sh.
//

#include "../src/Core/QueueFormatting.h"

#include <cmath>
#include <cstdio>
#include <string>

static int g_failures = 0;
static int g_checks = 0;

static void checkDuration(double seconds, const char* want, const char* name) {
    g_checks++;
    std::string got = queue_format::formatDurationSeconds(seconds);
    if (got != want) {
        g_failures++;
        printf("FAIL [%s] formatDurationSeconds(%g): got \"%s\" want \"%s\"\n",
               name, seconds, got.c_str(), want);
    }
}

static void checkStatus(size_t count, const char* want, const char* name) {
    g_checks++;
    std::string got = queue_format::statusTextForCount(count);
    if (got != want) {
        g_failures++;
        printf("FAIL [%s] statusTextForCount(%zu): got \"%s\" want \"%s\"\n",
               name, count, got.c_str(), want);
    }
}

int main() {
    // Non-positive lengths have no duration
    checkDuration(0.0, "--:--", "zero");
    checkDuration(-1.0, "--:--", "negative");

    // Untrusted metadata: NaN/inf and overflow-range values are rejected
    checkDuration(std::nan(""), "--:--", "nan");
    checkDuration(INFINITY, "--:--", "positive-infinity");
    checkDuration(-INFINITY, "--:--", "negative-infinity");
    checkDuration(1e19, "--:--", "beyond-int64");
    checkDuration(4000000000.0, "1111111:06:40", "beyond-int32-still-formats");

    // Fractional seconds truncate (matches the previous int cast)
    checkDuration(0.4, "0:00", "sub-second");
    checkDuration(59.999, "0:59", "truncate-not-round");

    // Minutes:seconds, seconds zero-padded
    checkDuration(1.0, "0:01", "one-second");
    checkDuration(59.0, "0:59", "under-a-minute");
    checkDuration(60.0, "1:00", "exactly-a-minute");
    checkDuration(61.0, "1:01", "minute-and-one");
    checkDuration(225.0, "3:45", "typical-track");
    checkDuration(600.0, "10:00", "ten-minutes");
    checkDuration(3599.0, "59:59", "under-an-hour");

    // Hours roll over to h:mm:ss with two-digit minutes
    checkDuration(3600.0, "1:00:00", "exactly-an-hour");
    checkDuration(3661.0, "1:01:01", "hour-padding");
    checkDuration(7325.0, "2:02:05", "two-hours");
    checkDuration(36000.0, "10:00:00", "ten-hours");

    // Status bar text
    checkStatus(0, "", "empty-queue");
    checkStatus(1, "1 item in queue", "singular");
    checkStatus(2, "2 items in queue", "plural");
    checkStatus(150, "150 items in queue", "large");

    if (g_failures) {
        printf("QueueFormattingTests: %d/%d checks FAILED\n", g_failures, g_checks);
        return 1;
    }
    printf("QueueFormattingTests: all %d checks passed\n", g_checks);
    return 0;
}
