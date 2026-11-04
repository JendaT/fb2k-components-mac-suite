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

// Bounded transport retry: which failures repeat, and how long the caller waits.
static void testRetryPolicy(void) {
    // Transient causes on an idempotent method repeat.
    CHECK([Policy shouldRetryMethod:@"GET" attempt:0 transportFailed:YES statusCode:0],
          "network error retries");
    CHECK([Policy shouldRetryMethod:@"GET" attempt:0 transportFailed:NO statusCode:500],
          "500 retries");
    CHECK([Policy shouldRetryMethod:@"GET" attempt:0 transportFailed:NO statusCode:503],
          "503 retries");
    CHECK([Policy shouldRetryMethod:@"GET" attempt:0 transportFailed:NO statusCode:429],
          "429 retries");
    CHECK([Policy shouldRetryMethod:@"HEAD" attempt:0 transportFailed:YES statusCode:0],
          "HEAD is idempotent too");

    // Verdicts do not.
    CHECK(![Policy shouldRetryMethod:@"GET" attempt:0 transportFailed:NO statusCode:401],
          "401 is handled by the refresh path, not retried here");
    CHECK(![Policy shouldRetryMethod:@"GET" attempt:0 transportFailed:NO statusCode:403],
          "403 never retries");
    CHECK(![Policy shouldRetryMethod:@"GET" attempt:0 transportFailed:NO statusCode:404],
          "404 never retries");
    CHECK(![Policy shouldRetryMethod:@"GET" attempt:0 transportFailed:NO statusCode:200],
          "success never retries");

    // A repeated mutation could add the same favorite twice.
    CHECK(![Policy shouldRetryMethod:@"POST" attempt:0 transportFailed:YES statusCode:0],
          "POST is not replayed");
    CHECK(![Policy shouldRetryMethod:@"DELETE" attempt:0 transportFailed:NO statusCode:500],
          "DELETE is not replayed");
    CHECK(![Policy shouldRetryMethod:nil attempt:0 transportFailed:YES statusCode:0],
          "nil method is not assumed idempotent");

    // The budget is finite.
    CHECK([Policy shouldRetryMethod:@"GET" attempt:kTidalMaxRequestAttempts - 2
                    transportFailed:YES statusCode:0], "second-to-last attempt may retry");
    CHECK(![Policy shouldRetryMethod:@"GET" attempt:kTidalMaxRequestAttempts - 1
                     transportFailed:YES statusCode:0], "last attempt does not retry");
    CHECK(![Policy shouldRetryMethod:@"GET" attempt:99 transportFailed:YES statusCode:0],
          "past the budget does not retry");

    // Backoff ladder, and the server's own Retry-After when it sent one.
    CHECK_EQ([Policy retryDelayForAttempt:0 retryAfterSeconds:-1], 0.5, "first backoff 500ms");
    CHECK_EQ([Policy retryDelayForAttempt:1 retryAfterSeconds:-1], 1.0, "second backoff 1s");
    CHECK_EQ([Policy retryDelayForAttempt:2 retryAfterSeconds:-1], 2.0, "third backoff 2s");
    CHECK_EQ([Policy retryDelayForAttempt:0 retryAfterSeconds:3], 3.0, "Retry-After wins");
    CHECK_EQ([Policy retryDelayForAttempt:0 retryAfterSeconds:600],
             kTidalMaxRetryAfterSeconds, "absurd Retry-After is clamped, not obeyed");
    CHECK([Policy retryDelayForAttempt:20 retryAfterSeconds:-1] <= kTidalMaxRetryAfterSeconds,
          "exponential ladder stays capped");
}

// A 403 is also how TIDAL says "not in your country" and "quota exceeded".
// Only the subscription sub-statuses may reach the quality cascade.
static void testForbiddenSubStatus(void) {
    JLTidalHTTPDecision *d = [Policy decisionForStatusCode:403 retryAfterHeader:nil
                                                 subStatus:0 userMessage:nil isRetry:NO];
    CHECK_EQ(d.errorCode, JLTidalErrorSubscriptionRequired,
             "no subStatus keeps the historical reading");

    d = [Policy decisionForStatusCode:403 retryAfterHeader:nil
                            subStatus:4033 userMessage:@"Your subscription does not include this"
                              isRetry:NO];
    CHECK_EQ(d.errorCode, JLTidalErrorSubscriptionRequired, "4033 is a subscription problem");
    CHECK_STREQ(d.message, @"Your subscription does not include this", "server message preferred");

    d = [Policy decisionForStatusCode:403 retryAfterHeader:nil
                            subStatus:4032 userMessage:@"Not available in your location"
                              isRetry:NO];
    CHECK_EQ(d.errorCode, JLTidalErrorAccessDenied, "geo-block is not a subscription problem");
    CHECK_STREQ(d.message, @"Not available in your location", "geo message surfaced");

    d = [Policy decisionForStatusCode:403 retryAfterHeader:nil
                            subStatus:4010 userMessage:nil isRetry:NO];
    CHECK_EQ(d.errorCode, JLTidalErrorAccessDenied, "quota is not a subscription problem");
    CHECK(d.message.length > 0, "falls back to a message naming the subStatus");

    // Unrelated statuses are unaffected by a sub-status being present.
    d = [Policy decisionForStatusCode:404 retryAfterHeader:nil
                            subStatus:4032 userMessage:@"x" isRetry:NO];
    CHECK_EQ(d.errorCode, JLTidalErrorTrackNotFound, "404 unchanged");
}

int main(void) {
    @autoreleasepool {
        testSuccessStatuses();
        testRateLimiting();
        testAuthRetry();
        testErrorStatuses();
        testRetryPolicy();
        testForbiddenSubStatus();
    }
    return testHarnessFinish("HTTPResponsePolicy");
}
