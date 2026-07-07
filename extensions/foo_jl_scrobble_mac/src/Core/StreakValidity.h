//
//  StreakValidity.h
//  foo_jl_scrobble_mac
//
//  Pure streak-cache validity predicate and the shared local-midnight
//  helper. Extracted from ScrobbleStreakCache / ScrobbleWidgetController
//  so the temporal invalidation rules (age, day rollover, timezone
//  change) are unit-testable with injected time.
//

#pragma once

#import <Foundation/Foundation.h>

/// Local midnight of `date` in the given calendar (single definition for
/// the day-bucketing previously duplicated across controller and cache)
static inline NSDate *ScrobbleLocalMidnight(NSDate *date, NSCalendar *calendar) {
    return [calendar startOfDayForDate:date];
}

/// A cached streak is fresh iff it was calculated, is younger than
/// cacheDuration, the local day has not rolled over, and the timezone
/// identifier is unchanged. All inputs injected for determinism.
static inline BOOL StreakCacheIsValid(NSDate *_Nullable calculatedAt,
                                      NSDate *now,
                                      NSTimeInterval cacheDuration,
                                      NSDate *_Nullable storedMidnight,
                                      NSDate *currentMidnight,
                                      NSString *_Nullable storedTimezoneName,
                                      NSString *currentTimezoneName) {
    // 1. Must have been calculated
    if (!calculatedAt) {
        return NO;
    }

    // 2. Check cache duration
    if ([now timeIntervalSinceDate:calculatedAt] > cacheDuration) {
        return NO;
    }

    // 3. Check day rollover
    if (!storedMidnight || ![storedMidnight isEqualToDate:currentMidnight]) {
        return NO;
    }

    // 4. Check timezone change
    if (!storedTimezoneName || ![storedTimezoneName isEqualToString:currentTimezoneName]) {
        return NO;
    }

    return YES;
}
