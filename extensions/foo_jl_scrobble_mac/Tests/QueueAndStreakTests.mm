//
//  QueueAndStreakTests.mm
//  foo_jl_scrobble_mac
//
//  Unit tests for ScrobbleQueueModel (pending/in-flight/dedup) and the
//  StreakValidity predicate. Compiled standalone (Foundation only);
//  gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/ScrobbleQueueModel.h"
#import "../src/Core/ScrobbleTrack.h"
#import "../src/Core/StreakValidity.h"

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

static ScrobbleTrack *makeTrack(NSString *artist, NSString *title, int64_t ts) {
    ScrobbleTrack *t = [[ScrobbleTrack alloc] initWithArtist:artist title:title duration:180];
    t.timestamp = ts;
    return t;
}

int main(void) {
    @autoreleasepool {

    const NSTimeInterval kNow = 1751000000;

    // --- FIFO: enqueue copies, dequeue moves to in-flight in order ---
    {
        g_context = "fifo";
        ScrobbleQueueModel *q = [[ScrobbleQueueModel alloc] init];
        ScrobbleTrack *a = makeTrack(@"A", @"1", kNow);
        [q enqueueTrack:a];
        [q enqueueTrack:makeTrack(@"B", @"2", kNow + 1)];
        [q enqueueTrack:makeTrack(@"C", @"3", kNow + 2)];
        CHECK(q.pendingCount == 3, "three pending");

        a.artist = @"MUTATED";
        CHECK([q.pendingTracks[0].artist isEqualToString:@"A"], "enqueue stored a copy");

        NSArray<ScrobbleTrack *> *batch = [q dequeueUpTo:2];
        CHECK(batch.count == 2, "dequeued two");
        CHECK([batch[0].artist isEqualToString:@"A"], "front first");
        CHECK(q.pendingCount == 1, "one left pending");
        CHECK(q.inFlightCount == 2, "two in flight");

        CHECK([q dequeueUpTo:5].count == 1, "dequeue clamps to available");
        CHECK([q dequeueUpTo:5].count == 0, "empty dequeue returns empty");
    }

    // --- markSubmitted removes from in-flight, requeue puts at front ---
    {
        g_context = "submit-requeue";
        ScrobbleQueueModel *q = [[ScrobbleQueueModel alloc] init];
        [q enqueueTrack:makeTrack(@"A", @"1", kNow)];
        [q enqueueTrack:makeTrack(@"B", @"2", kNow + 1)];
        [q enqueueTrack:makeTrack(@"C", @"3", kNow + 2)];

        NSArray<ScrobbleTrack *> *batch = [q dequeueUpTo:2];    // A, B in flight
        [q requeueTracks:batch];
        CHECK(q.inFlightCount == 0, "requeue empties in-flight");
        CHECK(q.pendingCount == 3, "requeue restores pending");
        CHECK([q.pendingTracks[0].artist isEqualToString:@"A"], "requeued at FRONT");
        CHECK([q.pendingTracks[2].artist isEqualToString:@"C"], "later track pushed back");

        batch = [q dequeueUpTo:3];
        [q markSubmitted:batch now:kNow + 10];
        CHECK(q.inFlightCount == 0 && q.pendingCount == 0, "submitted tracks leave both queues");
    }

    // --- Duplicate detection: recently-scrobbled and pending, 60s window ---
    {
        g_context = "dedup";
        ScrobbleQueueModel *q = [[ScrobbleQueueModel alloc] init];
        [q enqueueTrack:makeTrack(@"A", @"Song", kNow)];

        CHECK([q isDuplicateTrack:makeTrack(@"A", @"Song", kNow + 59) now:kNow + 59],
              "same track within 60s of a pending entry is a duplicate");
        CHECK(![q isDuplicateTrack:makeTrack(@"A", @"Song", kNow + 60) now:kNow + 60],
              "60s apart is a distinct play");
        CHECK(![q isDuplicateTrack:makeTrack(@"A", @"Other", kNow) now:kNow],
              "different title is not a duplicate");

        NSArray<ScrobbleTrack *> *batch = [q dequeueUpTo:1];
        [q markSubmitted:batch now:kNow + 5];
        CHECK([q isDuplicateTrack:makeTrack(@"A", @"Song", kNow + 30) now:kNow + 30],
              "recently scrobbled still detected after submission");

        // After the 30-minute window the entry is pruned
        CHECK(![q isDuplicateTrack:makeTrack(@"A", @"Song", kNow) now:kNow + 31 * 60],
              "pruned after duplicate window");
    }

    // --- removeTracksWithSubmissionIds / replacePendingTracks ---
    {
        g_context = "remove-replace";
        ScrobbleQueueModel *q = [[ScrobbleQueueModel alloc] init];
        ScrobbleTrack *a = makeTrack(@"A", @"1", kNow);
        ScrobbleTrack *b = makeTrack(@"B", @"2", kNow);
        [q enqueueTrack:a];
        [q enqueueTrack:b];

        [q removeTracksWithSubmissionIds:[NSSet setWithObject:q.pendingTracks[0].submissionId]];
        CHECK(q.pendingCount == 1, "removed by submission id");
        CHECK([q.pendingTracks[0].artist isEqualToString:@"B"], "correct one removed");

        [q replacePendingTracks:@[makeTrack(@"X", @"9", kNow)]];
        CHECK(q.pendingCount == 1 && [q.pendingTracks[0].artist isEqualToString:@"X"],
              "replace swaps the pending queue");
    }

    // --- StreakValidity: age, rollover, timezone ---
    {
        g_context = "streak-validity";
        NSDate *now = [NSDate dateWithTimeIntervalSince1970:kNow];
        NSDate *calc = [now dateByAddingTimeInterval:-100];
        NSDate *midnight = [NSDate dateWithTimeIntervalSince1970:kNow - 40000];

        CHECK(StreakCacheIsValid(calc, now, 3600, midnight, midnight,
                                 @"Europe/Prague", @"Europe/Prague"),
              "fresh cache is valid");
        CHECK(!StreakCacheIsValid(nil, now, 3600, midnight, midnight,
                                  @"Europe/Prague", @"Europe/Prague"),
              "never calculated");
        CHECK(!StreakCacheIsValid([now dateByAddingTimeInterval:-3700], now, 3600,
                                  midnight, midnight, @"Europe/Prague", @"Europe/Prague"),
              "older than cache duration");
        CHECK(!StreakCacheIsValid(calc, now, 3600, midnight,
                                  [midnight dateByAddingTimeInterval:86400],
                                  @"Europe/Prague", @"Europe/Prague"),
              "day rollover invalidates");
        CHECK(!StreakCacheIsValid(calc, now, 3600, nil, midnight,
                                  @"Europe/Prague", @"Europe/Prague"),
              "missing stored midnight invalidates");
        CHECK(!StreakCacheIsValid(calc, now, 3600, midnight, midnight,
                                  @"Europe/Prague", @"America/New_York"),
              "timezone change invalidates");
        CHECK(!StreakCacheIsValid(calc, now, 3600, midnight, midnight,
                                  nil, @"Europe/Prague"),
              "missing stored timezone invalidates");
    }

    // --- ScrobbleLocalMidnight: truncates to start of local day ---
    {
        g_context = "local-midnight";
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDate *someTime = [NSDate dateWithTimeIntervalSince1970:kNow];
        NSDate *midnight = ScrobbleLocalMidnight(someTime, cal);
        NSDateComponents *c = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute |
                                               NSCalendarUnitSecond) fromDate:midnight];
        CHECK(c.hour == 0 && c.minute == 0 && c.second == 0, "midnight components are zero");
        CHECK([midnight compare:someTime] != NSOrderedDescending, "midnight <= input");
        CHECK([ScrobbleLocalMidnight(midnight, cal) isEqualToDate:midnight], "idempotent");
    }

    }  // autoreleasepool

    printf("QueueAndStreakTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
