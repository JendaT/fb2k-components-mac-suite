//
//  StreamResolutionPolicyTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for the quality-fallback policy: cascade order, which errors
//  downgrade, DASH acceptance gating, and DRM handling.
//

#import <Foundation/Foundation.h>
#import "../src/Core/StreamResolutionPolicy.h"
#include "TestHarness.h"

typedef JLTidalStreamResolutionPolicy Policy;

static void testQualityCascade(void) {
    CHECK_EQ([Policy nextLowerQuality:JLTidalQualityHiResLossless], JLTidalQualityHiRes, "HiResLossless -> HiRes");
    CHECK_EQ([Policy nextLowerQuality:JLTidalQualityHiRes], JLTidalQualityLossless, "HiRes -> Lossless");
    CHECK_EQ([Policy nextLowerQuality:JLTidalQualityLossless], JLTidalQualityHigh, "Lossless -> High");
    CHECK_EQ([Policy nextLowerQuality:JLTidalQualityHigh], JLTidalQualityLow, "High -> Low");
    CHECK_EQ([Policy nextLowerQuality:JLTidalQualityLow], JLTidalQualityLow, "Low is the floor");
}

static void testErrorDecisions(void) {
    NSError *subscription = JLTidalError(JLTidalErrorSubscriptionRequired, @"Subscription required");
    NSError *network = JLTidalError(JLTidalErrorNetworkFailure, @"offline");
    NSError *auth = JLTidalError(JLTidalErrorNotAuthenticated, @"no token");

    // 403 downgrades while a lower quality exists
    JLTidalResolveDecision *d = [Policy decisionForError:subscription atQuality:JLTidalQualityHiRes];
    CHECK_EQ(d.action, JLTidalResolveActionRetryLower, "403 at HiRes retries lower");
    CHECK_EQ(d.nextQuality, JLTidalQualityLossless, "403 at HiRes -> Lossless");

    // 403 at the floor propagates the original error
    d = [Policy decisionForError:subscription atQuality:JLTidalQualityLow];
    CHECK_EQ(d.action, JLTidalResolveActionPropagateError, "403 at Low propagates");

    // Network/auth errors never downgrade
    d = [Policy decisionForError:network atQuality:JLTidalQualityHiResLossless];
    CHECK_EQ(d.action, JLTidalResolveActionPropagateError, "network error propagates");
    d = [Policy decisionForError:auth atQuality:JLTidalQualityHiResLossless];
    CHECK_EQ(d.action, JLTidalResolveActionPropagateError, "auth error propagates");
}

static void testPlaybackDecisions(void) {
    // Direct URL, no DRM -> accept
    JLTidalResolveDecision *d = [Policy decisionForPlaybackWithDirectURL:YES
        dashSegmentCount:0 dashMediaTemplate:nil dashEnabled:YES
        drmProtected:NO quality:JLTidalQualityLossless];
    CHECK_EQ(d.action, JLTidalResolveActionAccept, "direct URL accepted");

    // No direct URL but usable DASH (enabled) -> accept
    d = [Policy decisionForPlaybackWithDirectURL:NO
        dashSegmentCount:42 dashMediaTemplate:@"https://cdn/s_$Number$.mp4" dashEnabled:YES
        drmProtected:NO quality:JLTidalQualityLossless];
    CHECK_EQ(d.action, JLTidalResolveActionAccept, "DASH accepted when enabled");

    // Same DASH manifest with the pref disabled -> downgrade
    d = [Policy decisionForPlaybackWithDirectURL:NO
        dashSegmentCount:42 dashMediaTemplate:@"https://cdn/s_$Number$.mp4" dashEnabled:NO
        drmProtected:NO quality:JLTidalQualityLossless];
    CHECK_EQ(d.action, JLTidalResolveActionRetryLower, "DASH ignored when disabled");
    CHECK_EQ(d.nextQuality, JLTidalQualityHigh, "downgrades Lossless -> High");
    CHECK_EQ(d.failureCode, JLTidalErrorStreamNotAvailable, "reason is stream-not-available");

    // DASH with zero segments is not usable
    d = [Policy decisionForPlaybackWithDirectURL:NO
        dashSegmentCount:0 dashMediaTemplate:@"https://cdn/s_$Number$.mp4" dashEnabled:YES
        drmProtected:NO quality:JLTidalQualityHigh];
    CHECK_EQ(d.action, JLTidalResolveActionRetryLower, "zero segments -> retry");

    // Nothing playable at the floor -> fail StreamNotAvailable
    d = [Policy decisionForPlaybackWithDirectURL:NO
        dashSegmentCount:0 dashMediaTemplate:nil dashEnabled:YES
        drmProtected:NO quality:JLTidalQualityLow];
    CHECK_EQ(d.action, JLTidalResolveActionFail, "nothing playable at Low fails");
    CHECK_EQ(d.failureCode, JLTidalErrorStreamNotAvailable, "fails stream-not-available");
    CHECK(d.failureMessage.length > 0, "failure carries a message");

    // DRM downgrades even when a direct URL exists
    d = [Policy decisionForPlaybackWithDirectURL:YES
        dashSegmentCount:0 dashMediaTemplate:nil dashEnabled:YES
        drmProtected:YES quality:JLTidalQualityLossless];
    CHECK_EQ(d.action, JLTidalResolveActionRetryLower, "DRM retries lower");
    CHECK_EQ(d.failureCode, JLTidalErrorDRMProtected, "reason is DRM");

    // DRM at the floor -> fail DRMProtected
    d = [Policy decisionForPlaybackWithDirectURL:YES
        dashSegmentCount:0 dashMediaTemplate:nil dashEnabled:YES
        drmProtected:YES quality:JLTidalQualityLow];
    CHECK_EQ(d.action, JLTidalResolveActionFail, "DRM at Low fails");
    CHECK_EQ(d.failureCode, JLTidalErrorDRMProtected, "fails DRM-protected");
}

int main(void) {
    @autoreleasepool {
        testQualityCascade();
        testErrorDecisions();
        testPlaybackDecisions();
    }
    return testHarnessFinish("StreamResolutionPolicy");
}
