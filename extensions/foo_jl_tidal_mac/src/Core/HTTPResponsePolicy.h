//
//  HTTPResponsePolicy.h
//  foo_jl_tidal_mac
//
//  Pure HTTP status -> action/error mapping for Tidal API responses.
//  Foundation-only — no SDK, no network — unit-tested standalone
//  (Tests/HTTPResponsePolicyTests.mm). JLTidalAPI applies the decisions
//  (token refresh, rate-limiter bookkeeping, body parsing).
//

#pragma once

#import <Foundation/Foundation.h>
#import "TidalErrors.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, JLTidalHTTPAction) {
    JLTidalHTTPActionSuccess,      // 200/201/204: parse body (204/empty -> {})
    JLTidalHTTPActionRetryAuth,    // 401 on first attempt: refresh token, retry once
    JLTidalHTTPActionRateLimited,  // 429: fail rate-limited (see retryAfterSeconds)
    JLTidalHTTPActionFail,         // fail with errorCode/message
};

@interface JLTidalHTTPDecision : NSObject
@property (nonatomic, readonly) JLTidalHTTPAction action;
@property (nonatomic, readonly) JLTidalErrorCode errorCode;      // valid for Fail
@property (nonatomic, copy, readonly, nullable) NSString *message;
/// Valid for RateLimited: seconds parsed from the Retry-After header
/// (clamped to >= 1), or -1 when the header was absent and the caller
/// should use its own backoff.
@property (nonatomic, readonly) NSTimeInterval retryAfterSeconds;
@end

/// Total attempts for one logical request (initial try plus two retries),
/// matching the TIDAL Player spec's 3 attempts at 500/1000/2000 ms.
static const NSInteger kTidalMaxRequestAttempts = 3;

/// Longest server-requested Retry-After this client will actually wait.
/// A decoder thread is blocked on these; beyond this the honest answer is
/// to fail and let the user retry.
static const NSTimeInterval kTidalMaxRetryAfterSeconds = 8.0;

@interface JLTidalHTTPResponsePolicy : NSObject

/// Map a response status to an action. retryAfterHeader is the raw
/// Retry-After value if present (RFC 6585); isRetry indicates the request
/// already went through one 401-triggered refresh.
+ (JLTidalHTTPDecision *)decisionForStatusCode:(NSInteger)statusCode
                              retryAfterHeader:(nullable NSString *)retryAfterHeader
                                       isRetry:(BOOL)isRetry;

/// As above, plus TIDAL's error body. `subStatus` is the numeric `subStatus`
/// field (0 when absent) and `userMessage` the server's own explanation.
///
/// A 403 is not automatically "subscription required": it is also how TIDAL
/// answers a geo-block, a quota, and a forbidden playlist mutation. Only the
/// subscription sub-status should reach the quality cascade -- the rest must
/// propagate at once, with the server's message, instead of costing five
/// playbackinfo requests down the tiers.
+ (JLTidalHTTPDecision *)decisionForStatusCode:(NSInteger)statusCode
                              retryAfterHeader:(nullable NSString *)retryAfterHeader
                                     subStatus:(NSInteger)subStatus
                                   userMessage:(nullable NSString *)userMessage
                                       isRetry:(BOOL)isRetry;

/// Whether a failed attempt is worth repeating.
///
/// Only transient causes qualify — a transport error, 429 or 5xx — and only
/// for idempotent methods: re-sending a POST could add the same favorite or
/// playlist twice. 4xx is a verdict, not a hiccup, and is never retried.
/// `attempt` is 0-based; the last permitted attempt returns NO.
+ (BOOL)shouldRetryMethod:(nullable NSString *)method
                  attempt:(NSInteger)attempt
          transportFailed:(BOOL)transportFailed
               statusCode:(NSInteger)statusCode;

/// Backoff before the next attempt: 500/1000/2000 ms, overridden by the
/// server's Retry-After when it gave one (clamped to
/// kTidalMaxRetryAfterSeconds). `retryAfterSeconds` < 0 means no header.
+ (NSTimeInterval)retryDelayForAttempt:(NSInteger)attempt
                     retryAfterSeconds:(NSTimeInterval)retryAfterSeconds;

@end

NS_ASSUME_NONNULL_END
