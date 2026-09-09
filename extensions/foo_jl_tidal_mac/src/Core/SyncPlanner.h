//
//  SyncPlanner.h
//  foo_jl_tidal_mac
//
//  Pure planning logic for bidirectional playlist sync: naming round-trip,
//  folder-hierarchy path building, set-diff change planning, and push
//  decisions. Foundation-only — no fb2k SDK, no network — unit-tested
//  standalone (Tests/SyncPlannerTests.mm).
//
//  JLTidalPlaylistSync owns the orchestration (playlist_manager access,
//  API calls, dispatch groups) and feeds plain values in.
//

#pragma once

#import <Foundation/Foundation.h>
#import "TidalModels.h"
#import "TidalPlaylistSync.h"

NS_ASSUME_NONNULL_BEGIN

@interface JLTidalSyncPlanner : NSObject

#pragma mark - Naming

/// "TIDAL » [folderPath »] title" (Playlist Organizer delimiter convention)
+ (NSString *)foobarNameForTitle:(NSString *)title
                      folderPath:(nullable NSString *)folderPath;

/// Last delimiter-separated component; nil when not in the TIDAL namespace.
+ (nullable NSString *)tidalTitleFromFoobarName:(NSString *)foobarName;

+ (BOOL)isTidalSyncedName:(NSString *)foobarName;

/// "TIDAL » Favorite Tracks"
+ (NSString *)favoriteTracksName;

/// "TIDAL » Favorite Albums » <albumTitle>"
+ (NSString *)favoriteAlbumNameForTitle:(NSString *)albumTitle;

/// Cache key "__favalbum_<albumID>__" used to tag favorite-album changes.
+ (NSString *)favoriteAlbumKeyForAlbumID:(NSString *)albumID;

/// Inverse of favoriteAlbumKeyForAlbumID:.
+ (NSString *)albumIDFromFavoriteAlbumKey:(NSString *)key;

#pragma mark - Folder hierarchy

/// folderID -> delimiter-joined path, walking nested subfolders.
+ (NSDictionary<NSString *, NSString *> *)folderPathsForFolders:
    (NSArray<JLTidalPlaylistFolder *> *)folders;

/// playlist UUID -> folder path, walking nested subfolders.
+ (NSDictionary<NSString *, NSString *> *)playlistFolderPathsForFolders:
        (NSArray<JLTidalPlaylistFolder *> *)folders
                                                            folderPaths:
        (NSDictionary<NSString *, NSString *> *)folderPaths;

#pragma mark - Pull planning

+ (NSSet<NSString *> *)trackIDSetFromTracks:(NSArray<JLTidalTrack *> *)tracks;

/// Change for one Tidal playlist. foobarTrackIDs is nil when the foobar
/// playlist does not exist (-> Create); otherwise the track-ID sets are
/// diffed (-> Update or Unchanged).
+ (JLTidalSyncChange *)pullChangeForName:(NSString *)foobarName
                                    uuid:(NSString *)uuid
                             tidalTracks:(NSArray<JLTidalTrack *> *)tidalTracks
                          foobarTrackIDs:(nullable NSSet<NSString *> *)foobarTrackIDs;

/// Change for the favorites playlist. existingCount is -1 when the foobar
/// playlist does not exist; favorites diff by count only.
+ (JLTidalSyncChange *)favoritesPullChangeForName:(NSString *)name
                                             uuid:(NSString *)uuid
                                       tidalCount:(NSInteger)tidalCount
                                    existingCount:(NSInteger)existingCount;

/// Change for one favorite album (Create when absent, else Unchanged).
+ (JLTidalSyncChange *)favoriteAlbumPullChangeForAlbum:(JLTidalAlbum *)album
                                                exists:(BOOL)exists;

#pragma mark - Push planning

/// Playlists outside the TIDAL namespace and the special favorites
/// playlists never push.
+ (BOOL)shouldSkipPushForName:(NSString *)foobarName;

/// Create when the mapping is missing or Tidal no longer has the UUID;
/// otherwise a potential Update (track diff happens at apply time).
+ (JLTidalSyncChange *)pushChangeForName:(NSString *)foobarName
                                    uuid:(nullable NSString *)uuid
                         knownTidalUUIDs:(NSSet<NSString *> *)knownTidalUUIDs
                               itemCount:(NSInteger)itemCount;

/// Local track IDs not yet present on Tidal (order not preserved).
+ (NSArray<NSString *> *)trackIDsToAddFromLocalIDs:(NSArray<NSString *> *)localIDs
                                       tidalTracks:(NSArray<JLTidalTrack *> *)tidalTracks;

@end

NS_ASSUME_NONNULL_END
