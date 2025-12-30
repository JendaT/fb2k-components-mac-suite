//
//  RateLimiter.h
//  foo_jl_biography_mac
//
//  Token bucket rate limiter for API calls
//  Named BiographyRateLimiter to avoid collision with foo_jl_scrobble
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BiographyRateLimiter : NSObject

/// Initialize with rate and burst capacity
/// @param rate Tokens replenished per second
/// @param capacity Maximum tokens that can accumulate
- (instancetype)initWithTokensPerSecond:(double)rate
                          burstCapacity:(NSInteger)capacity NS_DESIGNATED_INITIALIZER;

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
