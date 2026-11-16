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

/// Everything the pull planner reads, captured before planning: remote state
/// from the API, local state from playlist_manager on the main thread, and
/// the sync map from its state queue. Plain values only.
@interface JLTidalPullSnapshot : NSObject
/// Every remote playlist, fetched or not.
@property (nonatomic, copy) NSArray<JLTidalPlaylist *> *playlists;
/// Playlist UUID -> local target name ("TIDAL » [folders »] title").
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *nameByUUID;
/// Playlist UUID -> tracks, for successful track fetches only.
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<JLTidalTrack *> *> *tracksByUUID;
/// Playlists whose track fetch failed: their remote state is unknown.
@property (nonatomic, copy) NSSet<NSString *> *failedUUIDs;
@property (nonatomic, copy) NSArray<JLTidalTrack *> *favoriteTracks;
@property (nonatomic) BOOL favoriteTracksFailed;
@property (nonatomic, copy) NSArray<JLTidalAlbum *> *favoriteAlbums;
@property (nonatomic) BOOL favoriteAlbumsFailed;
/// Local playlist name -> item count, every fb2k playlist (first occurrence
/// of a duplicate name wins, mirroring find_playlist).
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *localCountsByName;
/// Local playlist name -> TIDAL track IDs, for the target names and move
/// candidates that exist locally.
@property (nonatomic, copy) NSDictionary<NSString *, NSSet<NSString *> *> *localTrackIDsByName;
/// The sync map, both directions.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *nameToUUID;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *uuidToName;
@end

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

/// Cache key of the favorite tracks in the pull's track cache.
+ (NSString *)favoriteTracksKey;

/// The favorite-tracks name or any favorite-album name.
+ (BOOL)isFavoritesName:(NSString *)foobarName;

/// The local name a remote playlist may have had before: the sync map's name
/// for its UUID when that differs from the target, else the flat legacy name
/// "TIDAL » <title>" (every playlist pulled before folders were read). nil
/// when that is the target itself.
+ (nullable NSString *)moveCandidateForTargetName:(NSString *)targetName
                                            title:(NSString *)title
                                       mappedName:(nullable NSString *)mappedName;

/// The whole pull plan: one change per remote playlist (Create, Rename,
/// Update or Unchanged), the favorites, then Delete for local TIDAL names no
/// longer accounted for.
///
/// A Rename is planned only when all of these hold, otherwise the playlist
/// is planned as before (Create, Update or Unchanged):
/// - no local playlist has the target name, and no other remote playlist
///   has the same target;
/// - a local playlist has the move candidate's name;
/// - the sync map maps that name to no UUID or to this one;
/// - no other remote playlist claims that name, as candidate or as target;
/// - it is not a favorites name.
/// Its track diff is against the old playlist. Delete detection skips names
/// consumed by a Rename, and for a playlist whose track fetch failed it also
/// skips the target, the mapped name and the legacy name.
+ (NSArray<JLTidalSyncChange *> *)pullChangesForSnapshot:(JLTidalPullSnapshot *)snapshot;

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
