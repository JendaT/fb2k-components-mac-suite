//
//  ScrobbleCache.mm
//  foo_scrobble_mac
//
//  Persistent cache implementation
//

#import "ScrobbleCache.h"
#import "../Core/ScrobbleTrack.h"
#import "../Core/ScrobbleQueueModel.h"
#import "../Core/ScrobbleNotifications.h"

@interface ScrobbleCache ()
@property (nonatomic, strong) ScrobbleQueueModel* queueModel;
@property (nonatomic, strong) dispatch_queue_t syncQueue;
@property (nonatomic, copy) NSString* cachedFilePath;
@property (nonatomic, strong, nullable) NSTimer* saveDebouncTimer;
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
        _queueModel = [[ScrobbleQueueModel alloc] init];
        _syncQueue = dispatch_queue_create("com.foobar2000.foo_scrobble.cache", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Queue Operations

- (void)enqueueTrack:(ScrobbleTrack*)track {
    if (!track || !track.isValid) return;

    dispatch_sync(_syncQueue, ^{
        [self.queueModel enqueueTrack:track];
    });

    [self notifyChange];
}

- (NSArray<ScrobbleTrack*>*)dequeueTracksWithCount:(NSUInteger)count {
    __block NSArray<ScrobbleTrack*>* result = nil;

    dispatch_sync(_syncQueue, ^{
        result = [self.queueModel dequeueUpTo:count];
    });

    return result;
}

- (void)markTracksAsSubmitted:(NSArray<ScrobbleTrack*>*)tracks {
    if (tracks.count == 0) return;

    dispatch_sync(_syncQueue, ^{
        [self.queueModel markSubmitted:tracks now:[[NSDate date] timeIntervalSince1970]];
    });

    [self notifyChange];
    [self debouncedSave];
}

- (void)requeueTracks:(NSArray<ScrobbleTrack*>*)tracks {
    if (tracks.count == 0) return;

    dispatch_sync(_syncQueue, ^{
        [self.queueModel requeueTracks:tracks];
    });

    [self notifyChange];
    [self debouncedSave];
}

- (NSUInteger)pendingCount {
    __block NSUInteger count = 0;
    dispatch_sync(_syncQueue, ^{
        count = self.queueModel.pendingCount;
    });
    return count;
}

- (NSUInteger)inFlightCount {
    __block NSUInteger count = 0;
    dispatch_sync(_syncQueue, ^{
        count = self.queueModel.inFlightCount;
    });
    return count;
}

- (NSArray<ScrobbleTrack*>*)pendingTracks {
    __block NSArray* result = nil;
    dispatch_sync(_syncQueue, ^{
        result = self.queueModel.pendingTracks;
    });
    return result;
}

- (void)removeTracksWithSubmissionIds:(NSSet<NSString*>*)submissionIds {
    if (submissionIds.count == 0) return;

    dispatch_sync(_syncQueue, ^{
        [self.queueModel removeTracksWithSubmissionIds:submissionIds];
    });

    [self notifyChange];
    [self debouncedSave];
}

#pragma mark - Duplicate Detection

- (BOOL)isDuplicateTrack:(ScrobbleTrack*)track {
    if (!track || !track.artist || !track.title) return NO;

    __block BOOL isDuplicate = NO;

    dispatch_sync(_syncQueue, ^{
        isDuplicate = [self.queueModel isDuplicateTrack:track
                                                    now:[[NSDate date] timeIntervalSince1970]];
    });

    return isDuplicate;
}

#pragma mark - Persistence

- (NSString*)cacheFilePath {
    if (_cachedFilePath) return _cachedFilePath;

    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString* libraryDir = paths.firstObject;
    NSString* fb2kDir = [libraryDir stringByAppendingPathComponent:@"foobar2000-v2"];

    [[NSFileManager defaultManager] createDirectoryAtPath:fb2kDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    _cachedFilePath = [fb2kDir stringByAppendingPathComponent:@"scrobble_cache.plist"];
    return _cachedFilePath;
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
                [self.queueModel replacePendingTracks:tracks];
            } else if (error) {
                NSLog(@"[Scrobble] Cache decode error: %@ - deleting corrupted file", error.localizedDescription);
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            }
        } @catch (NSException* exception) {
            NSLog(@"[Scrobble] Cache exception: %@ - deleting corrupted file", exception.reason);
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }
    });
}

- (void)debouncedSave {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.saveDebouncTimer invalidate];
        self.saveDebouncTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                                target:self
                                                              selector:@selector(saveToDisk)
                                                              userInfo:nil
                                                               repeats:NO];
    });
}

- (void)saveToDisk {
    // Snapshot and write without blocking main thread
    dispatch_async(_syncQueue, ^{
        NSArray* toSave = self.queueModel.pendingTracks;
        NSString* path = [self cacheFilePath];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
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
                // Archive/write failure - will retry on next change
            }
        });
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
