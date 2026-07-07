//
//  StreamResolutionPolicy.mm
//  foo_jl_tidal_mac
//

#import "StreamResolutionPolicy.h"

@interface JLTidalResolveDecision ()
- (instancetype)initWithAction:(JLTidalResolveAction)action
                   nextQuality:(JLTidalQuality)nextQuality
                   failureCode:(JLTidalErrorCode)failureCode
                failureMessage:(NSString *)failureMessage;
@end

@implementation JLTidalResolveDecision

- (instancetype)initWithAction:(JLTidalResolveAction)action
                   nextQuality:(JLTidalQuality)nextQuality
                   failureCode:(JLTidalErrorCode)failureCode
                failureMessage:(NSString *)failureMessage {
    self = [super init];
    if (self) {
        _action = action;
        _nextQuality = nextQuality;
        _failureCode = failureCode;
        _failureMessage = [failureMessage copy];
    }
    return self;
}

@end

static JLTidalResolveDecision *decision(JLTidalResolveAction action,
                                        JLTidalQuality nextQuality,
                                        JLTidalErrorCode failureCode,
                                        NSString *failureMessage) {
    return [[JLTidalResolveDecision alloc] initWithAction:action
                                              nextQuality:nextQuality
                                              failureCode:failureCode
                                           failureMessage:failureMessage];
}

@implementation JLTidalStreamResolutionPolicy

+ (JLTidalQuality)nextLowerQuality:(JLTidalQuality)quality {
    switch (quality) {
        case JLTidalQualityHiResLossless:
            return JLTidalQualityHiRes;
        case JLTidalQualityHiRes:
            return JLTidalQualityLossless;
        case JLTidalQualityLossless:
            return JLTidalQualityHigh;
        case JLTidalQualityHigh:
            return JLTidalQualityLow;
        case JLTidalQualityLow:
            return JLTidalQualityLow;  // No lower quality
    }
}

+ (JLTidalResolveDecision *)decisionForError:(NSError *)error
                                   atQuality:(JLTidalQuality)quality {
    // Only fall back for subscription/quality errors (403). Auth errors
    // (401), network errors, rate limiting, and server errors should not
    // trigger fallback -- they'll fail at every quality level.
    if (error.code == JLTidalErrorSubscriptionRequired) {
        JLTidalQuality next = [self nextLowerQuality:quality];
        if (next != quality) {
            return decision(JLTidalResolveActionRetryLower, next,
                            JLTidalErrorSubscriptionRequired, nil);
        }
    }
    return decision(JLTidalResolveActionPropagateError, quality, JLTidalErrorInternal, nil);
}

+ (JLTidalResolveDecision *)decisionForPlaybackWithDirectURL:(BOOL)hasDirectURL
                                            dashSegmentCount:(NSInteger)dashSegmentCount
                                            dashMediaTemplate:(NSString *)dashMediaTemplate
                                                 dashEnabled:(BOOL)dashEnabled
                                                drmProtected:(BOOL)drmProtected
                                                     quality:(JLTidalQuality)quality {
    // Accept if we have either a direct URL OR a DASH SegmentTemplate
    // (when enabled in prefs).
    BOOL hasDASH = (dashEnabled && dashSegmentCount > 0 && dashMediaTemplate.length > 0);

    if (!hasDirectURL && !hasDASH) {
        JLTidalQuality next = [self nextLowerQuality:quality];
        if (next != quality) {
            return decision(JLTidalResolveActionRetryLower, next,
                            JLTidalErrorStreamNotAvailable, nil);
        }
        return decision(JLTidalResolveActionFail, quality, JLTidalErrorStreamNotAvailable,
                        @"No stream URL in response at any quality");
    }

    if (drmProtected) {
        JLTidalQuality next = [self nextLowerQuality:quality];
        if (next != quality) {
            return decision(JLTidalResolveActionRetryLower, next,
                            JLTidalErrorDRMProtected, nil);
        }
        return decision(JLTidalResolveActionFail, quality, JLTidalErrorDRMProtected,
                        @"Track is DRM protected at all quality levels");
    }

    return decision(JLTidalResolveActionAccept, quality, JLTidalErrorInternal, nil);
}

@end
