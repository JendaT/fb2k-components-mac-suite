//
//  RateLimiter.mm
//  foo_jl_tidal_mac
//
//  Exponential backoff rate limiter implementation
//

#import "RateLimiter.h"
#import "TidalConstants.h"

@interface JLTidalRateLimiter ()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) NSTimeInterval currentBackoff;
@property (nonatomic, strong, nullable) NSDate *rateLimitExpiry;
@end

@implementation JLTidalRateLimiter

+ (instancetype)shared {
    static JLTidalRateLimiter *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[JLTidalRateLimiter alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.foobar2000.tidal.ratelimiter", DISPATCH_QUEUE_SERIAL);
        _currentBackoff = 0;
        _rateLimitExpiry = nil;
    }
    return self;
}

- (NSTimeInterval)recordRateLimitHit {
    __block NSTimeInterval delay;

    dispatch_sync(self.queue, ^{
        // Calculate exponential backoff
        if (self.currentBackoff == 0) {
            self.currentBackoff = kTidalRateLimitInitialBackoff;
        } else {
            self.currentBackoff = MIN(self.currentBackoff * kTidalRateLimitBackoffMultiplier,
                                      kTidalRateLimitMaxBackoff);
        }

        // Set expiry time
        self.rateLimitExpiry = [NSDate dateWithTimeIntervalSinceNow:self.currentBackoff];
        delay = self.currentBackoff;
    });

    return delay;
}

- (void)recordSuccess {
    dispatch_sync(self.queue, ^{
        self.currentBackoff = 0;
        self.rateLimitExpiry = nil;
    });
}

- (NSTimeInterval)currentDelay {
    __block NSTimeInterval delay = 0;

    dispatch_sync(self.queue, ^{
        if (self.rateLimitExpiry) {
            NSTimeInterval remaining = [self.rateLimitExpiry timeIntervalSinceNow];
            if (remaining > 0) {
                delay = remaining;
            } else {
                // Rate limit has expired
                self.rateLimitExpiry = nil;
            }
        }
    });

    return delay;
}

- (BOOL)isRateLimited {
    return self.currentDelay > 0;
}

- (void)reset {
    dispatch_sync(self.queue, ^{
        self.currentBackoff = 0;
        self.rateLimitExpiry = nil;
    });
}

@end
