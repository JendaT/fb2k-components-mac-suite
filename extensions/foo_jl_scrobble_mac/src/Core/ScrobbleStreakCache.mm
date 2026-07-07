//
//  ScrobbleStreakCache.mm
//  foo_jl_scrobble_mac
//
//  In-memory cache for listening streak data with discovery state.
//

#import "ScrobbleStreakCache.h"
#import "ScrobbleConfig.h"
#import "StreakValidity.h"

@interface ScrobbleStreakCache ()
@property (nonatomic, strong, nullable, readwrite) NSUUID *discoveryToken;
@property (nonatomic, copy, nullable) NSString *currentUsername;
@end

@implementation ScrobbleStreakCache

#pragma mark - Singleton

+ (instancetype)shared {
    static ScrobbleStreakCache *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ScrobbleStreakCache alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self resetToDefaults];
    }
    return self;
}

#pragma mark - Private

- (void)resetToDefaults {
    _streakDays = 0;
    _scrobbledToday = NO;
    _isDiscoveryComplete = NO;
    _lastCheckedDay = 0;
    _discoveryInProgress = NO;
    _discoveryToken = nil;
    _estimatedDailyRate = 0.0;
    _calculatedAt = nil;
    _todayMidnight = nil;
    _calculatedTimezone = nil;
}

- (NSDate *)currentMidnight {
    return ScrobbleLocalMidnight([NSDate date], [NSCalendar currentCalendar]);
}

#pragma mark - Cache Validity

- (BOOL)isValid {
    return StreakCacheIsValid(_calculatedAt,
                              [NSDate date],
                              scrobble_config::getStreakCacheDuration(),
                              _todayMidnight,
                              [self currentMidnight],
                              _calculatedTimezone.name,
                              [NSTimeZone localTimeZone].name);
}

- (BOOL)needsMoreDiscovery {
    // Check if we have partial results but discovery was interrupted
    return !_isDiscoveryComplete && !_discoveryInProgress;
}

#pragma mark - Invalidation

- (void)invalidate {
    [self resetToDefaults];
}

- (void)invalidateForUsername:(NSString *)username {
    // If switching to a different user, clear everything
    if (![_currentUsername isEqualToString:username]) {
        [self resetToDefaults];
        _currentUsername = [username copy];
    }
}

#pragma mark - Discovery Token

- (void)setDiscoveryToken:(NSUUID *)token {
    _discoveryToken = token;
}

@end
