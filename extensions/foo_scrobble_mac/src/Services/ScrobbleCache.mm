//
//  ScrobbleCache.mm
//  foo_scrobble_mac
//
//  Persistent cache implementation
//

#import "ScrobbleCache.h"
#import "../Core/ScrobbleTrack.h"
#import "../Core/ScrobbleNotifications.h"

// Recent scrobbles window for duplicate detection (30 minutes)
static const NSTimeInterval kDuplicateWindow = 30 * 60;

@interface ScrobbleCache ()
@property (nonatomic, strong) NSMutableArray<ScrobbleTrack*>* pendingQueue;
@property (nonatomic, strong) NSMutableArray<ScrobbleTrack*>* inFlightQueue;
@property (nonatomic, strong) NSMutableArray<ScrobbleTrack*>* recentlyScrobbled;
@property (nonatomic, strong) dispatch_queue_t syncQueue;
@end

@implementation ScrobbleCache

#pragma mark - Singleton

+ (instancetype)shared {
    static ScrobbleCache* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ScrobbleCache alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pendingQueue = [NSMutableArray array];
        _inFlightQueue = [NSMutableArray array];
        _recentlyScrobbled = [NSMutableArray array];
        _syncQueue = dispatch_queue_create("com.foobar2000.foo_scrobble.cache", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Queue Operations

- (void)enqueueTrack:(ScrobbleTrack*)track {
    if (!track || !track.isValid) return;

    dispatch_sync(_syncQueue, ^{
        [self.pendingQueue addObject:[track copy]];
    });

    [self notifyChange];
}

- (NSArray<ScrobbleTrack*>*)dequeueTracksWithCount:(NSUInteger)count {
    __block NSArray<ScrobbleTrack*>* result = nil;

    dispatch_sync(_syncQueue, ^{
        NSUInteger available = MIN(count, self.pendingQueue.count);
        if (available == 0) {
            result = @[];
            return;
        }

        NSRange range = NSMakeRange(0, available);
        result = [self.pendingQueue subarrayWithRange:range];

        // Move to in-flight
        [self.inFlightQueue addObjectsFromArray:result];
        [self.pendingQueue removeObjectsInRange:range];
    });

    return result;
}

- (void)markTracksAsSubmitted:(NSArray<ScrobbleTrack*>*)tracks {
    if (tracks.count == 0) return;

    dispatch_sync(_syncQueue, ^{
        // Remove from in-flight
        for (ScrobbleTrack* track in tracks) {
            [self.inFlightQueue removeObject:track];

            // Add to recently scrobbled for duplicate detection
            [self.recentlyScrobbled addObject:track];
        }

        // Prune old entries from recently scrobbled
        [self pruneRecentlyScrobbled];
    });

    [self notifyChange];
    [self saveToDisk];
}

- (void)requeueTracks:(NSArray<ScrobbleTrack*>*)tracks {
    if (tracks.count == 0) return;

    dispatch_sync(_syncQueue, ^{
        // Remove from in-flight
        for (ScrobbleTrack* track in tracks) {
            [self.inFlightQueue removeObject:track];
        }

        // Add back to front of pending queue
        NSIndexSet* indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, tracks.count)];
        [self.pendingQueue insertObjects:tracks atIndexes:indexes];
    });

    [self notifyChange];
}

- (NSUInteger)pendingCount {
    __block NSUInteger count = 0;
    dispatch_sync(_syncQueue, ^{
        count = self.pendingQueue.count;
    });
    return count;
}

- (NSUInteger)inFlightCount {
    __block NSUInteger count = 0;
    dispatch_sync(_syncQueue, ^{
        count = self.inFlightQueue.count;
    });
    return count;
}

#pragma mark - Duplicate Detection

- (void)pruneRecentlyScrobbled {
    NSTimeInterval cutoff = [[NSDate date] timeIntervalSince1970] - kDuplicateWindow;

    NSMutableArray* toRemove = [NSMutableArray array];
    for (ScrobbleTrack* track in _recentlyScrobbled) {
        if (track.timestamp < cutoff) {
            [toRemove addObject:track];
        }
    }
    [_recentlyScrobbled removeObjectsInArray:toRemove];
}

- (BOOL)isDuplicateTrack:(ScrobbleTrack*)track {
    __block BOOL isDuplicate = NO;

    dispatch_sync(_syncQueue, ^{
        [self pruneRecentlyScrobbled];

        for (ScrobbleTrack* recent in self.recentlyScrobbled) {
            // Same track if same artist, title, and timestamp (within tolerance)
            if ([recent.artist isEqualToString:track.artist] &&
                [recent.title isEqualToString:track.title] &&
                ABS(recent.timestamp - track.timestamp) < 60) {
                isDuplicate = YES;
                break;
            }
        }

        // Also check pending and in-flight
        if (!isDuplicate) {
            for (ScrobbleTrack* pending in self.pendingQueue) {
                if ([pending.artist isEqualToString:track.artist] &&
                    [pending.title isEqualToString:track.title] &&
                    ABS(pending.timestamp - track.timestamp) < 60) {
                    isDuplicate = YES;
                    break;
                }
            }
        }
    });

    return isDuplicate;
}

#pragma mark - Persistence

- (NSString*)cacheFilePath {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString* libraryDir = paths.firstObject;
    NSString* fb2kDir = [libraryDir stringByAppendingPathComponent:@"foobar2000-v2"];

    // Create directory if needed
    [[NSFileManager defaultManager] createDirectoryAtPath:fb2kDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    return [fb2kDir stringByAppendingPathComponent:@"scrobble_cache.plist"];
}

- (void)loadFromDisk {
    dispatch_sync(_syncQueue, ^{
        NSString* path = [self cacheFilePath];

        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return;
        }

        @try {
            NSData* data = [NSData dataWithContentsOfFile:path];
            if (!data) return;

            NSError* error = nil;
            NSSet* classes = [NSSet setWithObjects:[NSArray class], [ScrobbleTrack class], nil];
            NSArray* tracks = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                                  fromData:data
                                                                     error:&error];
            if (tracks && !error) {
                [self.pendingQueue removeAllObjects];
                [self.pendingQueue addObjectsFromArray:tracks];
            }
        } @catch (NSException* exception) {
            // Corrupted cache - ignore and start fresh
        }
    });
}

- (void)saveToDisk {
    dispatch_async(_syncQueue, ^{
        NSString* path = [self cacheFilePath];

        NSArray* toSave = [self.pendingQueue copy];
        if (toSave.count == 0) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            return;
        }

        @try {
            NSError* error = nil;
            NSData* data = [NSKeyedArchiver archivedDataWithRootObject:toSave
                                                 requiringSecureCoding:YES
                                                                 error:&error];
            if (data && !error) {
                [data writeToFile:path atomically:YES];
            }
        } @catch (NSException* exception) {
            // Failed to save - will retry on next change
        }
    });
}

#pragma mark - Notifications

- (void)notifyChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ScrobbleCacheDidChangeNotification
                                                            object:self];
    });
}

@end
