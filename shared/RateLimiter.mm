//
//  RateLimiter.mm
//  shared
//
//  Token bucket rate limiter implementation
//

#import "RateLimiter.h"
#include <os/lock.h>

@implementation JLRateLimiter {
    double _tokensPerSecond;
    NSInteger _burstCapacity;
    double _availableTokens;
    CFAbsoluteTime _lastRefillTime;
    os_unfair_lock _lock;
}

- (instancetype)initWithTokensPerSecond:(double)rate burstCapacity:(NSInteger)capacity {
    self = [super init];
    if (self) {
        _tokensPerSecond = rate;
        _burstCapacity = capacity;
        _availableTokens = capacity;  // Start with full bucket
        _lastRefillTime = CFAbsoluteTimeGetCurrent();
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)refillTokensLocked {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime elapsed = now - _lastRefillTime;

    if (elapsed > 0) {
        double tokensToAdd = elapsed * _tokensPerSecond;
        _availableTokens = MIN(_burstCapacity, _availableTokens + tokensToAdd);
        _lastRefillTime = now;
    }
}

- (BOOL)tryAcquire {
    os_unfair_lock_lock(&_lock);

    [self refillTokensLocked];

    BOOL acquired = NO;
    if (_availableTokens >= 1.0) {
        _availableTokens -= 1.0;
        acquired = YES;
    }

    os_unfair_lock_unlock(&_lock);
    return acquired;
}

- (BOOL)acquireWithTimeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        if ([self tryAcquire]) {
            return YES;
        }

        NSTimeInterval wait = self.waitTimeForNextToken;
        if (wait <= 0) {
            continue;
        }

        NSTimeInterval remainingTime = [deadline timeIntervalSinceNow];
        if (remainingTime <= 0) {
            break;
        }

        NSTimeInterval sleepTime = MIN(wait, remainingTime);
        [NSThread sleepForTimeInterval:sleepTime];
    }

    return [self tryAcquire];
}

- (NSTimeInterval)waitTimeForNextToken {
    os_unfair_lock_lock(&_lock);

    [self refillTokensLocked];

    NSTimeInterval wait = 0;
    if (_availableTokens < 1.0) {
        double tokensNeeded = 1.0 - _availableTokens;
        wait = tokensNeeded / _tokensPerSecond;
    }

    os_unfair_lock_unlock(&_lock);
    return wait;
}

- (double)availableTokens {
    os_unfair_lock_lock(&_lock);
    [self refillTokensLocked];
    double tokens = _availableTokens;
    os_unfair_lock_unlock(&_lock);
    return tokens;
}

- (double)tokensPerSecond {
    return _tokensPerSecond;
}

- (NSInteger)burstCapacity {
    return _burstCapacity;
}

@end
