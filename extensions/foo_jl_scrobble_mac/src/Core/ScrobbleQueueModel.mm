//
//  ScrobbleQueueModel.mm
//  foo_jl_scrobble_mac
//
//  Pure scrobble queue state
//

#import "ScrobbleQueueModel.h"
#import "ScrobbleTrack.h"

// Recent scrobbles window for duplicate detection (30 minutes)
static const NSTimeInterval kDuplicateWindow = 30 * 60;

// Timestamp tolerance for treating two submissions as the same play
static const NSTimeInterval kDuplicateTimestampTolerance = 60;

@implementation ScrobbleQueueModel {
    NSMutableArray<ScrobbleTrack *> *_pendingQueue;
    NSMutableArray<ScrobbleTrack *> *_inFlightQueue;
    NSMutableArray<ScrobbleTrack *> *_recentlyScrobbled;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pendingQueue = [NSMutableArray array];
        _inFlightQueue = [NSMutableArray array];
        _recentlyScrobbled = [NSMutableArray array];
    }
    return self;
}

- (void)enqueueTrack:(ScrobbleTrack *)track {
    [_pendingQueue addObject:[track copy]];
}

- (NSArray<ScrobbleTrack *> *)dequeueUpTo:(NSUInteger)count {
    NSUInteger available = MIN(count, _pendingQueue.count);
    if (available == 0) {
        return @[];
    }

    NSRange range = NSMakeRange(0, available);
    NSArray *result = [_pendingQueue subarrayWithRange:range];

    // Move to in-flight
    [_inFlightQueue addObjectsFromArray:result];
    [_pendingQueue removeObjectsInRange:range];

    return result;
}

- (void)markSubmitted:(NSArray<ScrobbleTrack *> *)tracks now:(NSTimeInterval)now {
    for (ScrobbleTrack *track in tracks) {
        [_inFlightQueue removeObject:track];

        // Remember for duplicate detection
        [_recentlyScrobbled addObject:track];
    }

    [self pruneRecentlyScrobbledAt:now];
}

- (void)requeueTracks:(NSArray<ScrobbleTrack *> *)tracks {
    for (ScrobbleTrack *track in tracks) {
        [_inFlightQueue removeObject:track];
    }

    // Add back to front of pending queue, preserving order
    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, tracks.count)];
    [_pendingQueue insertObjects:tracks atIndexes:indexes];
}

- (void)removeTracksWithSubmissionIds:(NSSet<NSString *> *)submissionIds {
    NSMutableIndexSet *toRemove = [NSMutableIndexSet indexSet];
    [_pendingQueue enumerateObjectsUsingBlock:^(ScrobbleTrack *track, NSUInteger idx, BOOL *stop) {
        if ([submissionIds containsObject:track.submissionId]) {
            [toRemove addIndex:idx];
        }
    }];
    if (toRemove.count > 0) {
        [_pendingQueue removeObjectsAtIndexes:toRemove];
    }
}

- (void)pruneRecentlyScrobbledAt:(NSTimeInterval)now {
    NSTimeInterval cutoff = now - kDuplicateWindow;

    NSMutableIndexSet *toRemove = [NSMutableIndexSet indexSet];
    [_recentlyScrobbled enumerateObjectsUsingBlock:^(ScrobbleTrack *track, NSUInteger idx, BOOL *stop) {
        if (track.timestamp < cutoff) {
            [toRemove addIndex:idx];
        }
    }];
    if (toRemove.count > 0) {
        [_recentlyScrobbled removeObjectsAtIndexes:toRemove];
    }
}

static BOOL sameScrobble(ScrobbleTrack *a, ScrobbleTrack *b) {
    return [a.artist isEqualToString:b.artist] &&
           [a.title isEqualToString:b.title] &&
           ABS(a.timestamp - b.timestamp) < kDuplicateTimestampTolerance;
}

- (BOOL)isDuplicateTrack:(ScrobbleTrack *)track now:(NSTimeInterval)now {
    if (!track.artist || !track.title) return NO;

    [self pruneRecentlyScrobbledAt:now];

    for (ScrobbleTrack *recent in _recentlyScrobbled) {
        if (sameScrobble(recent, track)) return YES;
    }
    for (ScrobbleTrack *pending in _pendingQueue) {
        if (sameScrobble(pending, track)) return YES;
    }
    return NO;
}

- (void)replacePendingTracks:(NSArray<ScrobbleTrack *> *)tracks {
    [_pendingQueue removeAllObjects];
    [_pendingQueue addObjectsFromArray:tracks];
}

- (NSUInteger)pendingCount {
    return _pendingQueue.count;
}

- (NSUInteger)inFlightCount {
    return _inFlightQueue.count;
}

- (NSArray<ScrobbleTrack *> *)pendingTracks {
    return [_pendingQueue copy];
}

@end
