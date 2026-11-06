//
//  RateLimiter.h
//  foo_scrobble_mac
//
//  Token bucket rate limiter for Last.fm API
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RateLimiter : NSObject

/// Monotonic clock returning seconds; injectable for deterministic tests
typedef double (^RateLimiterClock)(void);

/// Initialize with rate and burst capacity, using the system clock
/// @param rate Tokens replenished per second
/// @param capacity Maximum tokens that can accumulate
- (instancetype)initWithTokensPerSecond:(double)rate
                          burstCapacity:(NSInteger)capacity;

/// Initialize with an injected clock (tests); pass nil for the system clock
- (instancetype)initWithTokensPerSecond:(double)rate
                          burstCapacity:(NSInteger)capacity
                                  clock:(nullable RateLimiterClock)clock NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Try to acquire a token for making a request
/// @return YES if token acquired, NO if rate limited
- (BOOL)tryAcquire;

/// How long to wait before next token is available (seconds)
@property (nonatomic, readonly) NSTimeInterval waitTimeForNextToken;

/// Current number of available tokens
@property (nonatomic, readonly) double availableTokens;

@end

NS_ASSUME_NONNULL_END
