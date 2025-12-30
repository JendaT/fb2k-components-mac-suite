//
//  RateLimiter.mm
//  foo_jl_biography_mac
//
//  Token bucket rate limiter implementation
//

#import "RateLimiter.h"

@implementation BiographyRateLimiter {
    double _tokensPerSecond;
    NSInteger _burstCapacity;
    double _availableTokens;
    CFAbsoluteTime _lastRefillTime;
}

- (instancetype)initWithTokensPerSecond:(double)rate burstCapacity:(NSInteger)capacity {
    self = [super init];
    if (self) {
        _tokensPerSecond = rate;
        _burstCapacity = capacity;
        _availableTokens = capacity;  // Start full
        _lastRefillTime = CFAbsoluteTimeGetCurrent();
    }
    return self;
}

- (void)refillTokens {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime elapsed = now - _lastRefillTime;

    if (elapsed > 0) {
        double tokensToAdd = elapsed * _tokensPerSecond;
        _availableTokens = MIN(_burstCapacity, _availableTokens + tokensToAdd);
        _lastRefillTime = now;
    }
}

- (BOOL)tryAcquire {
    [self refillTokens];

    if (_availableTokens >= 1.0) {
        _availableTokens -= 1.0;
        return YES;
    }

    return NO;
}

- (NSTimeInterval)waitTimeForNextToken {
    [self refillTokens];

    if (_availableTokens >= 1.0) {
        return 0;
    }

    double tokensNeeded = 1.0 - _availableTokens;
    return tokensNeeded / _tokensPerSecond;
}

- (double)availableTokens {
    [self refillTokens];
    return _availableTokens;
}

@end
