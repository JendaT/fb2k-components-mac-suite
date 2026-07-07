//
//  StreamResolutionPolicy.h
//  foo_jl_tidal_mac
//
//  Pure quality-fallback policy for stream resolution: which errors and
//  playback-info shapes trigger a downgrade, and what to fail with when the
//  cascade is exhausted. Foundation-only — no SDK, no network, no singletons —
//  unit-tested standalone (Tests/StreamResolutionPolicyTests.mm).
//  JLTidalStreamResolver owns the async plumbing and applies these decisions.
//

#pragma once

#import <Foundation/Foundation.h>
#import "../API/TidalConstants.h"
#import "TidalErrors.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, JLTidalResolveAction) {
    JLTidalResolveActionAccept,          // use this playback info
    JLTidalResolveActionRetryLower,      // retry at nextQuality
    JLTidalResolveActionFail,            // fail with failureCode/failureMessage
    JLTidalResolveActionPropagateError,  // fail with the original NSError
};

@interface JLTidalResolveDecision : NSObject
@property (nonatomic, readonly) JLTidalResolveAction action;
@property (nonatomic, readonly) JLTidalQuality nextQuality;      // valid for RetryLower
/// Reason code: for Fail it is the error to report; for RetryLower it is
/// why the downgrade happened (StreamNotAvailable, DRMProtected,
/// SubscriptionRequired) so the caller can log accordingly.
@property (nonatomic, readonly) JLTidalErrorCode failureCode;
@property (nonatomic, copy, readonly, nullable) NSString *failureMessage;
@end

@interface JLTidalStreamResolutionPolicy : NSObject

/// Quality cascade: HI_RES_LOSSLESS -> HI_RES -> LOSSLESS -> HIGH -> LOW.
/// Returns the input quality when there is nothing lower.
+ (JLTidalQuality)nextLowerQuality:(JLTidalQuality)quality;

/// Decision after an API error at the given quality. Only subscription/
/// quality errors (403) downgrade; auth, network, rate-limit and server
/// errors fail at every quality level, so they propagate immediately.
+ (JLTidalResolveDecision *)decisionForError:(NSError *)error
                                   atQuality:(JLTidalQuality)quality;

/// Decision after parsing playback info at the given quality.
/// A response is playable with either a direct URL or a usable DASH
/// SegmentTemplate (only when DASH is enabled in prefs).
+ (JLTidalResolveDecision *)decisionForPlaybackWithDirectURL:(BOOL)hasDirectURL
                                            dashSegmentCount:(NSInteger)dashSegmentCount
                                            dashMediaTemplate:(nullable NSString *)dashMediaTemplate
                                                 dashEnabled:(BOOL)dashEnabled
                                                drmProtected:(BOOL)drmProtected
                                                     quality:(JLTidalQuality)quality;

@end

NS_ASSUME_NONNULL_END
