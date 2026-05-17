//
//  LastFmClient+Private.h
//  foo_jl_scrobble_mac
//
//  Private class extension for internal LastFmClient methods.
//  Import in LastFmClient.mm only, not in other files.
//

#pragma once

#import "LastFmClient.h"

NS_ASSUME_NONNULL_BEGIN

/// Internal state for a streak discovery operation
@interface LastFmStreakDiscoveryState : NSObject
@property (nonatomic, copy) NSString *username;
@property (nonatomic, strong) NSUUID *token;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) NSInteger currentStreak;
@property (nonatomic, assign) NSInteger daysChecked;
@property (nonatomic, assign) BOOL scrobbledToday;
@property (nonatomic, assign) BOOL useBatchStrategy;      // YES = batch, NO = daily queries
@property (nonatomic, assign) CGFloat estimatedDailyRate;
@property (nonatomic, assign) NSInteger retryCount;
@property (nonatomic, assign) NSTimeInterval currentBackoff;
@property (nonatomic, copy, nullable) LastFmStreakProgressBlock progressBlock;
@property (nonatomic, copy) LastFmStreakCompletion completionBlock;
@end

@interface LastFmClient ()

/// Active streak discovery operations (keyed by NSUUID).
/// Access must be synchronized (all access happens on main thread).
@property (nonatomic, strong) NSMutableDictionary<NSUUID*, LastFmStreakDiscoveryState*> *activeDiscoveries;

/// Cache for scraped artist image URLs (artist name lowercase -> NSURL or NSNull for not found)
/// Thread-safe; auto-evicts under memory pressure.
@property (nonatomic, strong) NSCache<NSString*, id> *artistImageCache;

/// Fetch a page of recent tracks
/// @param username Last.fm username
/// @param fromTimestamp Start of time range (UTC timestamp)
/// @param toTimestamp End of time range (UTC timestamp)
/// @param page Page number (1-indexed)
/// @param limit Tracks per page (max 200)
/// @param completion Returns tracks array, total pages, and error
- (void)fetchRecentTracksPage:(NSString*)username
                         from:(NSTimeInterval)fromTimestamp
                           to:(NSTimeInterval)toTimestamp
                         page:(NSInteger)page
                        limit:(NSInteger)limit
                   completion:(void(^)(NSArray* _Nullable tracks, NSInteger totalPages, NSError* _Nullable error))completion;

/// Check if a specific day has any scrobbles
/// @param username Last.fm username
/// @param date The date to check (will use local timezone midnight boundaries)
/// @param completion Returns whether any scrobbles exist for that day
- (void)checkDayHasScrobbles:(NSString*)username
                        date:(NSDate*)date
                  completion:(void(^)(BOOL hasScrobbles, NSError* _Nullable error))completion;

/// Continue streak discovery for the given state (internal recursive method)
- (void)continueStreakDiscovery:(LastFmStreakDiscoveryState*)state;

/// Schedule next request with rate limiting
- (void)scheduleNextRequest:(LastFmStreakDiscoveryState*)state;

@end

NS_ASSUME_NONNULL_END
