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

@interface JLTidalHTTPResponsePolicy : NSObject

/// Map a response status to an action. retryAfterHeader is the raw
/// Retry-After value if present (RFC 6585); isRetry indicates the request
/// already went through one 401-triggered refresh.
+ (JLTidalHTTPDecision *)decisionForStatusCode:(NSInteger)statusCode
                              retryAfterHeader:(nullable NSString *)retryAfterHeader
                                       isRetry:(BOOL)isRetry;

@end

NS_ASSUME_NONNULL_END
