//
//  ScrobbleCache.h
//  foo_scrobble_mac
//
//  Persistent cache for pending scrobbles
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ScrobbleTrack;

/// Notification posted when cache contents change
extern NSNotificationName const ScrobbleCacheDidChangeNotification;

@interface ScrobbleCache : NSObject

/// Shared cache instance
+ (instancetype)shared;

#pragma mark - Queue Operations

/// Add a track to the pending queue
- (void)enqueueTrack:(ScrobbleTrack*)track;

/// Get next batch of tracks for submission (up to count)
/// Marks returned tracks as pending submission
- (NSArray<ScrobbleTrack*>*)dequeueTracksWithCount:(NSUInteger)count;

/// Mark tracks as successfully scrobbled (removes from cache)
- (void)markTracksAsSubmitted:(NSArray<ScrobbleTrack*>*)tracks;

/// Return tracks to queue on failure (for retry)
- (void)requeueTracks:(NSArray<ScrobbleTrack*>*)tracks;

/// Number of pending scrobbles
@property (nonatomic, readonly) NSUInteger pendingCount;

/// Number of tracks currently being submitted
@property (nonatomic, readonly) NSUInteger inFlightCount;

#pragma mark - Persistence

/// Load cache from disk
- (void)loadFromDisk;

/// Save cache to disk
- (void)saveToDisk;

#pragma mark - Duplicate Prevention

/// Check if track was recently scrobbled (within 30 min, same timestamp)
- (BOOL)isDuplicateTrack:(ScrobbleTrack*)track;

@end

NS_ASSUME_NONNULL_END
