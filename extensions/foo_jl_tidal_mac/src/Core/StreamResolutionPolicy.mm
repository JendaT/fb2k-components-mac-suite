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
        // HI_RES (MQA) is skipped: TIDAL retired MQA on 2024-07-24, the
        // official SDK marks the value deprecated, and python-tidal removed it
        // outright. Asking for it costs a round trip that can only answer with
        // something else. Responses that still say HI_RES are parsed normally.
        case JLTidalQualityHiResLossless:
            return JLTidalQualityLossless;
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
                                                 previewOnly:(BOOL)previewOnly
                                              previewReason:(NSString *)previewReason
                                                     quality:(JLTidalQuality)quality {
    // A preview is a full, well-formed, playable response carrying ~30s of
    // audio. Retrying lower would just fetch another sample, and accepting it
    // hands fb2k a track that stops a third of the way through a seekbar built
    // from catalogue duration. Fail with the server's own reason instead.
    if (previewOnly) {
        NSString *message = previewReason.length > 0
            ? [NSString stringWithFormat:@"TIDAL returned a preview clip, not the full track (%@)", previewReason]
            : @"TIDAL returned a preview clip, not the full track";
        return decision(JLTidalResolveActionFail, quality, JLTidalErrorPreviewOnly, message);
    }

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
