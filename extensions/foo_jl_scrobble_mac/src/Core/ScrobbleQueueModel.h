//
//  ScrobbleQueueModel.h
//  foo_jl_scrobble_mac
//
//  Pure scrobble queue state: pending -> in-flight -> recently-scrobbled
//  transitions plus duplicate detection. Extracted from ScrobbleCache so
//  the list algebra is unit-testable; the cache keeps the dispatch queue,
//  persistence, and notifications and forwards to this model. NOT
//  thread-safe -- the owner serializes access. Time is injected.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ScrobbleTrack;

@interface ScrobbleQueueModel : NSObject

/// Append a copy of the track to the pending queue
- (void)enqueueTrack:(ScrobbleTrack *)track;

/// Move up to `count` tracks from the front of pending into in-flight
/// and return them (empty array when nothing is pending)
- (NSArray<ScrobbleTrack *> *)dequeueUpTo:(NSUInteger)count;

/// Submission succeeded (or tracks were dropped): remove from in-flight,
/// remember for duplicate detection, prune entries older than the
/// duplicate window relative to `now` (unix seconds)
- (void)markSubmitted:(NSArray<ScrobbleTrack *> *)tracks now:(NSTimeInterval)now;

/// Submission failed but is retriable: remove from in-flight and put
/// back at the FRONT of pending so order is preserved
- (void)requeueTracks:(NSArray<ScrobbleTrack *> *)tracks;

/// Remove pending tracks by submission id (user deleted them in the UI)
- (void)removeTracksWithSubmissionIds:(NSSet<NSString *> *)submissionIds;

/// Same artist+title with a timestamp within 60s of a recently-scrobbled
/// or pending track counts as a duplicate
- (BOOL)isDuplicateTrack:(ScrobbleTrack *)track now:(NSTimeInterval)now;

/// Replace the pending queue wholesale (loading persisted state)
- (void)replacePendingTracks:(NSArray<ScrobbleTrack *> *)tracks;

@property (nonatomic, readonly) NSUInteger pendingCount;
@property (nonatomic, readonly) NSUInteger inFlightCount;
@property (nonatomic, readonly) NSArray<ScrobbleTrack *> *pendingTracks;

@end

NS_ASSUME_NONNULL_END
