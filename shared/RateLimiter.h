//
//  RateLimiter.h
//  shared
//
//  Generic token bucket rate limiter for API calls
//  Thread-safe implementation supporting configurable rate and burst capacity
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Token bucket rate limiter for controlling API request frequency
/// Thread-safe: can be used from multiple threads concurrently
@interface JLRateLimiter : NSObject

/// Initialize with rate and burst capacity
/// @param rate Tokens replenished per second (e.g., 1.0 for 1 request/sec)
/// @param capacity Maximum tokens that can accumulate (burst capacity)
- (instancetype)initWithTokensPerSecond:(double)rate
                          burstCapacity:(NSInteger)capacity NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Try to acquire a token for making a request (non-blocking)
/// @return YES if token acquired, NO if rate limited
- (BOOL)tryAcquire;

/// Acquire a token, waiting if necessary (blocking)
/// @param timeout Maximum time to wait for a token
/// @return YES if token acquired within timeout, NO if timed out
- (BOOL)acquireWithTimeout:(NSTimeInterval)timeout;

/// How long to wait before next token is available (seconds)
/// Returns 0 if a token is currently available
@property (nonatomic, readonly) NSTimeInterval waitTimeForNextToken;

/// Current number of available tokens (may be fractional)
@property (nonatomic, readonly) double availableTokens;

/// Configured tokens per second rate
@property (nonatomic, readonly) double tokensPerSecond;

/// Configured burst capacity
@property (nonatomic, readonly) NSInteger burstCapacity;

@end

NS_ASSUME_NONNULL_END
