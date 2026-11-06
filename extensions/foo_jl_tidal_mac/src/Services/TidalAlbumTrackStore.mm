//
//  TidalAlbumTrackStore.mm
//  foo_jl_tidal_mac
//

#import "TidalAlbumTrackStore.h"
#import "TidalStreamResolver.h"
#import "../API/TidalAPI.h"
#include "../Core/TidalLog.h"

// Lists are small (an album is ~100 bytes a track); this only bounds a long
// session of browsing.
static const NSUInteger kMaxAlbums = 300;

@implementation JLTidalAlbumTrackStore {
    NSCache<NSString *, NSArray<JLTidalTrack *> *> *_tracks;      // thread-safe itself
    NSMutableDictionary<NSString *, dispatch_group_t> *_inFlight;  // @synchronized(self)
}

+ (instancetype)shared {
    static JLTidalAlbumTrackStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[JLTidalAlbumTrackStore alloc] init]; });
    return store;
}

- (instancetype)init {
    if ((self = [super init])) {
        _tracks = [[NSCache alloc] init];
        _tracks.countLimit = kMaxAlbums;
        _inFlight = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)setTracks:(NSArray<JLTidalTrack *> *)tracks forAlbumID:(NSString *)albumID {
    if (albumID.length == 0) return;
    [_tracks setObject:[tracks copy] forKey:albumID];
}

- (void)prefetchAlbumID:(NSString *)albumID {
    [self fetchIfNeeded:albumID];
}

// The group to wait on for an album being fetched; nil when it is already
// known (or has no ID).
- (nullable dispatch_group_t)fetchIfNeeded:(NSString *)albumID {
    if (albumID.length == 0) return nil;
    dispatch_group_t group;
    @synchronized (self) {
        if ([_tracks objectForKey:albumID]) return nil;
        group = _inFlight[albumID];
        if (group) return group;
        group = dispatch_group_create();
        dispatch_group_enter(group);
        _inFlight[albumID] = group;
    }
    [[JLTidalAPI shared] getAlbumTracksForAlbumID:albumID
                                       completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        if (error) {
            tidal::logDebug([[NSString stringWithFormat:@"Album %@ track list not fetched: %@",
                              albumID, error.localizedDescription] UTF8String]);
        } else {
            NSArray<JLTidalTrack *> *list = tracks ?: @[];
            [self->_tracks setObject:list forKey:albumID];
            // Saves the info reader a request per track once they are dropped.
            [[JLTidalStreamResolver shared] seedMetadataForTracks:list];
        }
        @synchronized (self) {
            [self->_inFlight removeObjectForKey:albumID];
        }
        dispatch_group_leave(group);
    }];
    return group;
}

- (NSDictionary<NSString *, NSArray<JLTidalTrack *> *> *)waitForAlbumIDs:(NSArray<NSString *> *)albumIDs
                                                                 timeout:(NSTimeInterval)timeout {
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    NSMutableArray<dispatch_group_t> *pending = [NSMutableArray array];
    for (NSString *albumID in albumIDs) {
        dispatch_group_t group = [self fetchIfNeeded:albumID];
        if (group) [pending addObject:group];
    }
    for (dispatch_group_t group in pending) {
        if (dispatch_group_wait(group, deadline) != 0) break;  // out of time
    }
    NSMutableDictionary<NSString *, NSArray<JLTidalTrack *> *> *found = [NSMutableDictionary dictionary];
    for (NSString *albumID in albumIDs) {
        NSArray<JLTidalTrack *> *tracks = [_tracks objectForKey:albumID];
        if (tracks) found[albumID] = tracks;
    }
    return found;
}

@end
