//
//  SyncPlanner.mm
//  foo_jl_tidal_mac
//
//  Also hosts the JLTidalSyncChange / JLTidalSyncReport value classes
//  (declared in TidalPlaylistSync.h) so the planner and its tests link
//  without the SDK-coupled sync engine.
//

#import "SyncPlanner.h"

#pragma mark - JLTidalSyncChange

@implementation JLTidalSyncChange

- (instancetype)initWithType:(JLTidalSyncChangeType)type
                        name:(NSString *)name
                 tracksAdded:(NSInteger)added
               tracksRemoved:(NSInteger)removed
                   tidalUUID:(NSString *)uuid {
    self = [super init];
    if (self) {
        _changeType = type;
        _playlistName = [name copy];
        _tracksAdded = added;
        _tracksRemoved = removed;
        _tidalUUID = [uuid copy];
    }
    return self;
}

@end

#pragma mark - JLTidalSyncReport

@implementation JLTidalSyncReport

- (instancetype)initWithChanges:(NSArray<JLTidalSyncChange *> *)changes {
    self = [super init];
    if (self) {
        _changes = [changes copy];
        NSInteger created = 0, updated = 0, deleted = 0, unchanged = 0;
        for (JLTidalSyncChange *c in changes) {
            switch (c.changeType) {
                case JLTidalSyncChangeTypeCreate: created++; break;
                case JLTidalSyncChangeTypeUpdate: updated++; break;
                case JLTidalSyncChangeTypeDelete: deleted++; break;
                case JLTidalSyncChangeTypeUnchanged: unchanged++; break;
            }
        }
        _totalCreated = created;
        _totalUpdated = updated;
        _totalDeleted = deleted;
        _totalUnchanged = unchanged;
    }
    return self;
}

- (NSString *)summary {
    NSMutableString *s = [NSMutableString string];
    if (_totalCreated > 0) [s appendFormat:@"%ld new", (long)_totalCreated];
    if (_totalUpdated > 0) {
        if (s.length > 0) [s appendString:@", "];
        [s appendFormat:@"%ld updated", (long)_totalUpdated];
    }
    if (_totalDeleted > 0) {
        if (s.length > 0) [s appendString:@", "];
        [s appendFormat:@"%ld removed", (long)_totalDeleted];
    }
    if (_totalUnchanged > 0) {
        if (s.length > 0) [s appendString:@", "];
        [s appendFormat:@"%ld unchanged", (long)_totalUnchanged];
    }
    if (s.length == 0) [s appendString:@"No changes"];
    return [s copy];
}

@end

#pragma mark - JLTidalSyncPlanner

@implementation JLTidalSyncPlanner

#pragma mark Naming

+ (NSString *)foobarNameForTitle:(NSString *)title
                      folderPath:(NSString *)folderPath {
    if (folderPath.length > 0) {
        return [NSString stringWithFormat:@"%@%@%@%@%@",
                kTidalSyncPrefix, kTidalSyncDelimiter,
                folderPath, kTidalSyncDelimiter,
                title];
    }
    return [NSString stringWithFormat:@"%@%@%@",
            kTidalSyncPrefix, kTidalSyncDelimiter,
            title];
}

+ (NSString *)tidalTitleFromFoobarName:(NSString *)foobarName {
    if (![self isTidalSyncedName:foobarName]) return nil;

    // Split by delimiter, last component is the playlist title
    NSArray<NSString *> *parts = [foobarName componentsSeparatedByString:kTidalSyncDelimiter];
    return parts.lastObject;
}

+ (BOOL)isTidalSyncedName:(NSString *)foobarName {
    NSString *prefix = [kTidalSyncPrefix stringByAppendingString:kTidalSyncDelimiter];
    return [foobarName hasPrefix:prefix];
}

+ (NSString *)favoriteTracksName {
    return [self foobarNameForTitle:kTidalSyncFavoriteTracks folderPath:nil];
}

+ (NSString *)favoriteAlbumNameForTitle:(NSString *)albumTitle {
    return [self foobarNameForTitle:albumTitle folderPath:kTidalSyncFavoriteAlbums];
}

+ (NSString *)favoriteAlbumKeyForAlbumID:(NSString *)albumID {
    return [NSString stringWithFormat:@"__favalbum_%@__", albumID];
}

+ (NSString *)albumIDFromFavoriteAlbumKey:(NSString *)key {
    NSString *albumID = [key stringByReplacingOccurrencesOfString:@"__favalbum_" withString:@""];
    return [albumID stringByReplacingOccurrencesOfString:@"__" withString:@""];
}

#pragma mark Folder hierarchy

+ (void)buildFolderPaths:(NSArray<JLTidalPlaylistFolder *> *)folders
              parentPath:(NSString *)parentPath
                    into:(NSMutableDictionary<NSString *, NSString *> *)paths {
    for (JLTidalPlaylistFolder *folder in folders) {
        NSString *path = parentPath.length > 0
            ? [NSString stringWithFormat:@"%@%@%@", parentPath, kTidalSyncDelimiter, folder.name]
            : folder.name;
        paths[folder.folderID] = path;

        if (folder.subfolders.count > 0) {
            [self buildFolderPaths:folder.subfolders parentPath:path into:paths];
        }
    }
}

+ (NSDictionary<NSString *, NSString *> *)folderPathsForFolders:
    (NSArray<JLTidalPlaylistFolder *> *)folders {
    NSMutableDictionary<NSString *, NSString *> *paths = [NSMutableDictionary dictionary];
    [self buildFolderPaths:folders parentPath:nil into:paths];
    return [paths copy];
}

+ (void)mapPlaylistsToFolders:(NSArray<JLTidalPlaylistFolder *> *)folders
                        paths:(NSDictionary<NSString *, NSString *> *)folderPaths
                         into:(NSMutableDictionary<NSString *, NSString *> *)playlistFolderPaths {
    for (JLTidalPlaylistFolder *folder in folders) {
        NSString *folderPath = folderPaths[folder.folderID];
        for (NSString *uuid in folder.playlistUUIDs) {
            playlistFolderPaths[uuid] = folderPath;
        }
        if (folder.subfolders.count > 0) {
            [self mapPlaylistsToFolders:folder.subfolders paths:folderPaths into:playlistFolderPaths];
        }
    }
}

+ (NSDictionary<NSString *, NSString *> *)playlistFolderPathsForFolders:
        (NSArray<JLTidalPlaylistFolder *> *)folders
                                                            folderPaths:
        (NSDictionary<NSString *, NSString *> *)folderPaths {
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    [self mapPlaylistsToFolders:folders paths:folderPaths into:result];
    return [result copy];
}

#pragma mark Pull planning

+ (NSSet<NSString *> *)trackIDSetFromTracks:(NSArray<JLTidalTrack *> *)tracks {
    NSMutableSet *set = [NSMutableSet setWithCapacity:tracks.count];
    for (JLTidalTrack *t in tracks) {
        [set addObject:t.trackID];
    }
    return set;
}

+ (JLTidalSyncChange *)pullChangeForName:(NSString *)foobarName
                                    uuid:(NSString *)uuid
                             tidalTracks:(NSArray<JLTidalTrack *> *)tidalTracks
                          foobarTrackIDs:(NSSet<NSString *> *)foobarTrackIDs {
    if (!foobarTrackIDs) {
        return [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeCreate
                                                  name:foobarName
                                           tracksAdded:tidalTracks.count
                                         tracksRemoved:0
                                             tidalUUID:uuid];
    }

    NSSet<NSString *> *tidalTrackIDs = [self trackIDSetFromTracks:tidalTracks];
    NSMutableSet *toAdd = [tidalTrackIDs mutableCopy];
    [toAdd minusSet:foobarTrackIDs];
    NSMutableSet *toRemove = [foobarTrackIDs mutableCopy];
    [toRemove minusSet:tidalTrackIDs];

    if (toAdd.count > 0 || toRemove.count > 0) {
        return [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeUpdate
                                                  name:foobarName
                                           tracksAdded:toAdd.count
                                         tracksRemoved:toRemove.count
                                             tidalUUID:uuid];
    }
    return [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeUnchanged
                                              name:foobarName
                                       tracksAdded:0
                                     tracksRemoved:0
                                         tidalUUID:uuid];
}

+ (JLTidalSyncChange *)favoritesPullChangeForName:(NSString *)name
                                             uuid:(NSString *)uuid
                                       tidalCount:(NSInteger)tidalCount
                                    existingCount:(NSInteger)existingCount {
    if (existingCount < 0) {
        return [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeCreate
                                                  name:name
                                           tracksAdded:tidalCount
                                         tracksRemoved:0
                                             tidalUUID:uuid];
    }
    if (existingCount != tidalCount) {
        return [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeUpdate
                                                  name:name
                                           tracksAdded:tidalCount
                                         tracksRemoved:existingCount
                                             tidalUUID:uuid];
    }
    return [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeUnchanged
                                              name:name
                                       tracksAdded:0
                                     tracksRemoved:0
                                         tidalUUID:uuid];
}

+ (JLTidalSyncChange *)favoriteAlbumPullChangeForAlbum:(JLTidalAlbum *)album
                                                exists:(BOOL)exists {
    NSString *albumName = [self favoriteAlbumNameForTitle:album.title];
    NSString *albumKey = [self favoriteAlbumKeyForAlbumID:album.albumID];

    if (!exists) {
        return [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeCreate
                                                  name:albumName
                                           tracksAdded:album.numberOfTracks
                                         tracksRemoved:0
                                             tidalUUID:albumKey];
    }
    return [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeUnchanged
                                              name:albumName
                                       tracksAdded:0
                                     tracksRemoved:0
                                         tidalUUID:albumKey];
}

#pragma mark Push planning

+ (BOOL)shouldSkipPushForName:(NSString *)foobarName {
    if (![self isTidalSyncedName:foobarName]) return YES;
    // Skip special playlists (favorites)
    if ([foobarName containsString:kTidalSyncFavoriteTracks]) return YES;
    if ([foobarName containsString:kTidalSyncFavoriteAlbums]) return YES;
    return NO;
}

+ (JLTidalSyncChange *)pushChangeForName:(NSString *)foobarName
                                    uuid:(NSString *)uuid
                         knownTidalUUIDs:(NSSet<NSString *> *)knownTidalUUIDs
                               itemCount:(NSInteger)itemCount {
    if (!uuid || ![knownTidalUUIDs containsObject:uuid]) {
        // New playlist (not on Tidal yet)
        return [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeCreate
                                                  name:foobarName
                                           tracksAdded:itemCount
                                         tracksRemoved:0
                                             tidalUUID:nil];
    }
    // Existing - track diff would require fetching Tidal tracks; mark as
    // potential update for the preview
    return [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeUpdate
                                              name:foobarName
                                       tracksAdded:0
                                     tracksRemoved:0
                                         tidalUUID:uuid];
}

+ (NSArray<NSString *> *)trackIDsToAddFromLocalIDs:(NSArray<NSString *> *)localIDs
                                       tidalTracks:(NSArray<JLTidalTrack *> *)tidalTracks {
    NSSet<NSString *> *tidalSet = [self trackIDSetFromTracks:tidalTracks];
    NSMutableSet *toAdd = [[NSSet setWithArray:localIDs] mutableCopy];
    [toAdd minusSet:tidalSet];
    return [toAdd allObjects];
}

@end
