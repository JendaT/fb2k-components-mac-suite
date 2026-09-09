//
//  ScrobblePolicy.h
//  foo_jl_scrobble_mac
//
//  Pure submission-failure policy: maps a Last.fm error to the action the
//  service must take, and owns the exponential backoff schedule. No state,
//  no singletons; unit-testable.
//

#pragma once

#import <Foundation/Foundation.h>
#import "../LastFm/LastFmErrors.h"

/// What ScrobbleService should do about a failed batch submission
typedef NS_ENUM(NSInteger, ScrobbleErrorAction) {
    ScrobbleErrorActionReauth,   // Session dead: sign out, requeue tracks
    ScrobbleErrorActionSuspend,  // API key rejected: stop calling, requeue tracks
    ScrobbleErrorActionRetry,    // Transient: requeue tracks, back off
    ScrobbleErrorActionDrop,     // Permanent rejection: discard tracks
};

// Exponential backoff schedule
static const NSTimeInterval kScrobbleInitialBackoff = 5.0;
static const NSTimeInterval kScrobbleMaxBackoff = 300.0;  // 5 minutes
static const double kScrobbleBackoffMultiplier = 2.0;

static inline ScrobbleErrorAction ScrobbleActionForErrorCode(LastFmErrorCode code) {
    if (LastFmErrorRequiresReauth(code)) return ScrobbleErrorActionReauth;
    if (LastFmErrorShouldSuspend(code)) return ScrobbleErrorActionSuspend;
    if (LastFmErrorIsRetriable(code)) return ScrobbleErrorActionRetry;
    return ScrobbleErrorActionDrop;
}

/// Next delay after a retriable failure: doubles, capped at 5 minutes
static inline NSTimeInterval ScrobbleNextBackoff(NSTimeInterval current) {
    return MIN(current * kScrobbleBackoffMultiplier, kScrobbleMaxBackoff);
}
