//
//  RateLimiter.h
//  foo_jl_tidal_mac
//
//  Exponential backoff rate limiter for API requests
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JLTidalRateLimiter : NSObject

/// Shared rate limiter instance
+ (instancetype)shared;

/// Record a rate limit response (429)
/// Returns the delay in seconds before the next request should be made
- (NSTimeInterval)recordRateLimitHit;

/// Record a successful response - resets backoff
- (void)recordSuccess;

/// Get current delay for next request (0 if no delay needed)
@property (nonatomic, readonly) NSTimeInterval currentDelay;

/// Whether we're currently rate limited
@property (nonatomic, readonly, getter=isRateLimited) BOOL rateLimited;

/// Reset all rate limiting state
- (void)reset;

@end

NS_ASSUME_NONNULL_END
