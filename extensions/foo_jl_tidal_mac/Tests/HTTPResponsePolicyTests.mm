//
//  HTTPResponsePolicyTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for the HTTP status -> action/error mapping.
//

#import <Foundation/Foundation.h>
#import "../src/Core/HTTPResponsePolicy.h"
#include "TestHarness.h"

typedef JLTidalHTTPResponsePolicy Policy;

static JLTidalHTTPDecision *decide(NSInteger status) {
    return [Policy decisionForStatusCode:status retryAfterHeader:nil isRetry:NO];
}

static void testSuccessStatuses(void) {
    CHECK_EQ(decide(200).action, JLTidalHTTPActionSuccess, "200 succeeds");
    CHECK_EQ(decide(201).action, JLTidalHTTPActionSuccess, "201 succeeds");
    CHECK_EQ(decide(204).action, JLTidalHTTPActionSuccess, "204 succeeds");
}

static void testRateLimiting(void) {
    JLTidalHTTPDecision *d = [Policy decisionForStatusCode:429 retryAfterHeader:@"5" isRetry:NO];
    CHECK_EQ(d.action, JLTidalHTTPActionRateLimited, "429 rate-limited");
    CHECK(d.retryAfterSeconds == 5.0, "Retry-After 5 parsed, got %f", d.retryAfterSeconds);

    d = [Policy decisionForStatusCode:429 retryAfterHeader:@"0" isRetry:NO];
    CHECK(d.retryAfterSeconds == 1.0, "Retry-After 0 clamps to 1s, got %f", d.retryAfterSeconds);

    d = [Policy decisionForStatusCode:429 retryAfterHeader:@"garbage" isRetry:NO];
    CHECK(d.retryAfterSeconds == 1.0, "unparsable Retry-After clamps to 1s, got %f", d.retryAfterSeconds);

    d = [Policy decisionForStatusCode:429 retryAfterHeader:nil isRetry:NO];
    CHECK(d.retryAfterSeconds == -1, "absent Retry-After -> caller backoff, got %f", d.retryAfterSeconds);

    // isRetry does not change rate-limit handling
    d = [Policy decisionForStatusCode:429 retryAfterHeader:@"3" isRetry:YES];
    CHECK_EQ(d.action, JLTidalHTTPActionRateLimited, "429 rate-limited on retry too");
}

static void testAuthRetry(void) {
    JLTidalHTTPDecision *d = [Policy decisionForStatusCode:401 retryAfterHeader:nil isRetry:NO];
    CHECK_EQ(d.action, JLTidalHTTPActionRetryAuth, "first 401 retries auth");

    d = [Policy decisionForStatusCode:401 retryAfterHeader:nil isRetry:YES];
    CHECK_EQ(d.action, JLTidalHTTPActionFail, "second 401 fails");
    CHECK_EQ(d.errorCode, JLTidalErrorNotAuthenticated, "second 401 -> not authenticated");
    CHECK_STREQ(d.message, @"Authentication required", "401 message");
}

static void testErrorStatuses(void) {
    JLTidalHTTPDecision *d = decide(403);
    CHECK_EQ(d.action, JLTidalHTTPActionFail, "403 fails");
    CHECK_EQ(d.errorCode, JLTidalErrorSubscriptionRequired, "403 -> subscription required");

    d = decide(404);
    CHECK_EQ(d.errorCode, JLTidalErrorTrackNotFound, "404 -> track not found");

    d = decide(500);
    CHECK_EQ(d.errorCode, JLTidalErrorServerError, "500 -> server error");
    d = decide(503);
    CHECK_EQ(d.errorCode, JLTidalErrorServerError, "503 -> server error");
    CHECK_STREQ(d.message, @"Server error: HTTP 503", "5xx message carries status");

    d = decide(418);
    CHECK_EQ(d.errorCode, JLTidalErrorInvalidResponse, "418 -> invalid response");
    CHECK_STREQ(d.message, @"Unexpected status: HTTP 418", "unexpected message carries status");

    d = decide(302);
    CHECK_EQ(d.errorCode, JLTidalErrorInvalidResponse, "redirect -> invalid response");
}

int main(void) {
    @autoreleasepool {
        testSuccessStatuses();
        testRateLimiting();
        testAuthRetry();
        testErrorStatuses();
    }
    return testHarnessFinish("HTTPResponsePolicy");
}
