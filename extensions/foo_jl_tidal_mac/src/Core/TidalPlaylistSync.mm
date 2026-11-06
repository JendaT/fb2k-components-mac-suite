//
//  TidalPlaylistSync.mm
//  foo_jl_tidal_mac
//
//  Bidirectional playlist sync between Tidal and foobar2000
//

#import "TidalPlaylistSync.h"
#import "TidalErrors.h"
#include <atomic>
#include <memory>
#import "../Services/TidalStreamResolver.h"
#import "TidalConfig.h"
#import "TidalModels.h"
#import "SyncPlanner.h"
#import "URLUtils.h"
#import "../API/TidalAPI.h"
#import "../Integration/TidalPlaylistLock.h"
#include "../fb2k_sdk.h"

// JLTidalSyncChange / JLTidalSyncReport implementations live in
// SyncPlanner.mm so the pure planner and its tests link without this
// SDK-coupled orchestration file.

#pragma mark - JLTidalPlaylistSync

static NSString * const kSyncMapKey = @"foo_tidal.sync_map";

@interface JLTidalPlaylistSync ()
// uuidToNameMap / nameToUUIDMap are confined to stateQueue: every mutation
// and saveMappings runs there so concurrent completion handlers cannot
// corrupt the maps or race the save.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *uuidToNameMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *nameToUUIDMap;
@property (nonatomic, strong) dispatch_queue_t stateQueue;

// Cached data from preview (used during apply)
@property (nonatomic, strong) NSDictionary<NSString *, NSArray<JLTidalTrack *> *> *cachedPlaylistTracks;
@property (nonatomic, strong) NSDictionary<NSString *, JLTidalPlaylist *> *cachedPlaylists;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *cachedFolderPaths;
@end

@implementation JLTidalPlaylistSync

+ (instancetype)shared {
    static JLTidalPlaylistSync *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[JLTidalPlaylistSync alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _uuidToNameMap = [NSMutableDictionary dictionary];
        _nameToUUIDMap = [NSMutableDictionary dictionary];
        _stateQueue = dispatch_queue_create("com.foobar2000.tidal.sync.state", DISPATCH_QUEUE_SERIAL);
        _cachedPlaylistTracks = @{};
        _cachedPlaylists = @{};
        _cachedFolderPaths = @{};
        [self loadMappings];
    }
    return self;
}

#pragma mark - Naming

- (NSString *)foobarNameForPlaylist:(JLTidalPlaylist *)playlist
                         folderPath:(NSString *)folderPath {
    return [JLTidalSyncPlanner foobarNameForTitle:playlist.title folderPath:folderPath];
}

- (NSString *)tidalTitleFromFoobarName:(NSString *)foobarName {
    return [JLTidalSyncPlanner tidalTitleFromFoobarName:foobarName];
}

- (BOOL)isTidalSyncedName:(NSString *)foobarName {
    return [JLTidalSyncPlanner isTidalSyncedName:foobarName];
}

#pragma mark - Pull from Tidal (Preview)

- (void)previewPullFromTidalWithCompletion:(JLTidalSyncPreviewCompletion)completion {
    tidal::logInfo("PlaylistSync: previewing pull from Tidal");

    dispatch_group_t group = dispatch_group_create();
    __block NSArray<JLTidalPlaylist *> *playlists = nil;
    __block NSArray<JLTidalPlaylistFolder *> *folders = nil;
    __block NSArray<JLTidalTrack *> *favTracks = nil;
    __block NSArray<JLTidalAlbum *> *favAlbums = nil;
    __block NSError *playlistsError = nil;
    __block NSError *foldersError = nil;
    __block NSError *favTracksError = nil;
    __block NSError *favAlbumsError = nil;

    // Fetch playlists (paginated inside the API - full list or error)
    dispatch_group_enter(group);
    [[JLTidalAPI shared] getUserPlaylistsWithCompletion:^(NSArray<JLTidalPlaylist *> *result, NSError *error) {
        playlistsError = error;
        playlists = result ?: @[];
        dispatch_group_leave(group);
    }];

    // Fetch folders (v2). NOT an acceptable fallback to treat as empty: local
    // names embed the folder path, so an empty folder list renames every
    // foldered playlist to a flat "TIDAL > X" and the planner then proposes
    // Delete for every local name that no longer appears -- exactly the
    // "a failed fetch is never an empty collection" rule stated three lines
    // below for favourites.
    dispatch_group_enter(group);
    [[JLTidalAPI shared] getPlaylistFoldersWithCompletion:^(NSArray<JLTidalPlaylistFolder *> *result, NSError *error) {
        if (error) {
            tidal::logError([[NSString stringWithFormat:@"PlaylistSync: folder fetch failed: %@",
                              error.localizedDescription] UTF8String]);
            foldersError = error;
        }
        folders = result ?: @[];
        dispatch_group_leave(group);
    }];

    // Fetch all favorite tracks. A failed fetch is recorded, never treated
    // as an empty collection - that would destroy the local playlist.
    dispatch_group_enter(group);
    [[JLTidalAPI shared] getAllFavoriteTracksWithCompletion:^(NSArray<JLTidalTrack *> *result, NSError *error) {
        favTracksError = error;
        favTracks = result ?: @[];
        dispatch_group_leave(group);
    }];

    // Fetch all favorite albums (same failure semantics)
    dispatch_group_enter(group);
    [[JLTidalAPI shared] getAllFavoriteAlbumsWithCompletion:^(NSArray<JLTidalAlbum *> *result, NSError *error) {
        favAlbumsError = error;
        favAlbums = result ?: @[];
        dispatch_group_leave(group);
    }];

    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (playlistsError) {
            // Without the authoritative playlist list nothing can be planned
            // safely - in particular no deletes may be proposed.
            completion(nil, playlistsError);
            return;
        }
        if (foldersError) {
            // Same reasoning: local names embed the folder path, so planning
            // against an unverified folder tree proposes a rename (Create +
            // Delete) for every foldered playlist.
            completion(nil, foldersError);
            return;
        }

        // Build folder path mapping and UUID -> folder path mapping
        NSDictionary<NSString *, NSString *> *folderPaths =
            [JLTidalSyncPlanner folderPathsForFolders:folders];
        NSDictionary<NSString *, NSString *> *playlistFolderPaths =
            [JLTidalSyncPlanner playlistFolderPathsForFolders:folders folderPaths:folderPaths];

        // Fetch tracks for each playlist with bounded concurrency. Failures
        // are recorded per playlist and exclude it from planning - a fetch
        // failure must never look like an empty remote playlist.
        dispatch_group_t tracksGroup = dispatch_group_create();
        NSMutableDictionary<NSString *, NSArray<JLTidalTrack *> *> *allTracks = [NSMutableDictionary dictionary];
        NSMutableSet<NSString *> *failedUUIDs = [NSMutableSet set];
        __block NSError *firstTrackError = nil;
        dispatch_queue_t writeQueue = dispatch_queue_create("com.foobar2000.tidal.sync.trackwrite", DISPATCH_QUEUE_SERIAL);
        // Completions run on the URL session's queue, so signaling there
        // cannot deadlock this loop (which runs on a global queue thread).
        dispatch_semaphore_t fetchSlots = dispatch_semaphore_create(4);

        for (JLTidalPlaylist *playlist in playlists) {
            dispatch_semaphore_wait(fetchSlots, DISPATCH_TIME_FOREVER);
            dispatch_group_enter(tracksGroup);
            [[JLTidalAPI shared] getAllPlaylistTracksForPlaylistID:playlist.playlistUUID
                                                        completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
                dispatch_sync(writeQueue, ^{
                    if (error) {
                        [failedUUIDs addObject:playlist.playlistUUID];
                        if (!firstTrackError) firstTrackError = error;
                    } else {
                        allTracks[playlist.playlistUUID] = tracks ?: @[];
                    }
                });
                dispatch_semaphore_signal(fetchSlots);
                dispatch_group_leave(tracksGroup);
            }];
        }

        dispatch_group_notify(tracksGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self finishPullPreviewWithPlaylists:playlists
                             playlistFolderPaths:playlistFolderPaths
                                       allTracks:[allTracks copy]
                                     failedUUIDs:[failedUUIDs copy]
                                 firstTrackError:firstTrackError
                                       favTracks:favTracks
                                  favTracksError:favTracksError
                                       favAlbums:favAlbums
                                  favAlbumsError:favAlbumsError
                                      completion:completion];
        });
    });
}

// Phase 2 of the pull preview: snapshot fb2k playlist state on the main
// thread (playlist_manager is main-thread-only per fb2k SDK), then plan
// off-main on the snapshots.
- (void)finishPullPreviewWithPlaylists:(NSArray<JLTidalPlaylist *> *)playlists
                   playlistFolderPaths:(NSDictionary<NSString *, NSString *> *)playlistFolderPaths
                             allTracks:(NSDictionary<NSString *, NSArray<JLTidalTrack *> *> *)allTracks
                           failedUUIDs:(NSSet<NSString *> *)failedUUIDs
                       firstTrackError:(NSError *)firstTrackError
                             favTracks:(NSArray<JLTidalTrack *> *)favTracks
                        favTracksError:(NSError *)favTracksError
                             favAlbums:(NSArray<JLTidalAlbum *> *)favAlbums
                        favAlbumsError:(NSError *)favAlbumsError
                            completion:(JLTidalSyncPreviewCompletion)completion {
    // If every track/favorites fetch failed, the preview has nothing
    // trustworthy to plan with - fail it instead of proposing changes.
    NSUInteger attempted = playlists.count + 2;
    NSUInteger failed = failedUUIDs.count + (favTracksError ? 1 : 0) + (favAlbumsError ? 1 : 0);
    if (attempted > 0 && failed == attempted) {
        NSError *err = firstTrackError ?: favTracksError ?: favAlbumsError;
        tidal::logError([[NSString stringWithFormat:@"PlaylistSync: preview aborted, all %lu fetches failed: %@",
                          (unsigned long)failed, err.localizedDescription] UTF8String]);
        completion(nil, err);
        return;
    }

    // Names are pure derivations - compute before the main-thread hop.
    NSMutableDictionary<NSString *, NSString *> *nameByUUID = [NSMutableDictionary dictionary];
    for (JLTidalPlaylist *playlist in playlists) {
        NSString *folderPath = playlistFolderPaths[playlist.playlistUUID];
        nameByUUID[playlist.playlistUUID] = [self foobarNameForPlaylist:playlist folderPath:folderPath];
    }

    fb2k::inMainThread([self, playlists, playlistFolderPaths, allTracks, failedUUIDs,
                        favTracks, favTracksError, favAlbums, favAlbumsError,
                        nameByUUID, completion]() {
        auto pm = playlist_manager::get();

        // Snapshot: name -> item count for every fb2k playlist (first
        // occurrence wins, mirroring find_playlist for duplicate names).
        NSMutableDictionary<NSString *, NSNumber *> *countsByName = [NSMutableDictionary dictionary];
        t_size count = pm->get_playlist_count();
        for (t_size i = 0; i < count; i++) {
            pfc::string8 name;
            pm->playlist_get_name(i, name);
            NSString *n = [NSString stringWithUTF8String:name.c_str()];
            if (!countsByName[n]) {
                countsByName[n] = @(pm->playlist_get_item_count(i));
            }
        }

        // Snapshot: track-ID sets for the playlists we will diff.
        NSMutableDictionary<NSString *, NSSet<NSString *> *> *localTrackIDsByName = [NSMutableDictionary dictionary];
        for (NSString *uuid in allTracks) {
            NSString *foobarName = nameByUUID[uuid];
            if (!foobarName) continue;
            pfc::string8 nameStr([foobarName UTF8String]);
            t_size idx = pm->find_playlist(nameStr, nameStr.length());
            if (idx != SIZE_MAX) {
                localTrackIDsByName[foobarName] =
                    [self trackIDSetFromPlaylist:idx count:pm->playlist_get_item_count(idx)];
            }
        }

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self planPullPreviewWithPlaylists:playlists
                           playlistFolderPaths:playlistFolderPaths
                                     allTracks:allTracks
                                   failedUUIDs:failedUUIDs
                                     favTracks:favTracks
                                favTracksError:favTracksError
                                     favAlbums:favAlbums
                                favAlbumsError:favAlbumsError
                                    nameByUUID:nameByUUID
                                  countsByName:countsByName
                            localTrackIDsByName:localTrackIDsByName
                                    completion:completion];
        });
    });
}

// Phase 3 of the pull preview: pure planning on snapshots, off-main.
- (void)planPullPreviewWithPlaylists:(NSArray<JLTidalPlaylist *> *)playlists
                 playlistFolderPaths:(NSDictionary<NSString *, NSString *> *)playlistFolderPaths
                           allTracks:(NSDictionary<NSString *, NSArray<JLTidalTrack *> *> *)allTracks
                         failedUUIDs:(NSSet<NSString *> *)failedUUIDs
                           favTracks:(NSArray<JLTidalTrack *> *)favTracks
                      favTracksError:(NSError *)favTracksError
                           favAlbums:(NSArray<JLTidalAlbum *> *)favAlbums
                      favAlbumsError:(NSError *)favAlbumsError
                          nameByUUID:(NSDictionary<NSString *, NSString *> *)nameByUUID
                        countsByName:(NSDictionary<NSString *, NSNumber *> *)countsByName
                 localTrackIDsByName:(NSDictionary<NSString *, NSSet<NSString *> *> *)localTrackIDsByName
                          completion:(JLTidalSyncPreviewCompletion)completion {
    NSMutableArray<JLTidalSyncChange *> *changes = [NSMutableArray array];
    // Remote names whose state could not be verified (fetch failed): they
    // are excluded from planning and protected from delete detection.
    NSMutableSet<NSString *> *protectedNames = [NSMutableSet set];
    NSMutableDictionary<NSString *, JLTidalPlaylist *> *playlistMap = [NSMutableDictionary dictionary];

    for (JLTidalPlaylist *playlist in playlists) {
        NSString *foobarName = nameByUUID[playlist.playlistUUID];
        playlistMap[playlist.playlistUUID] = playlist;
        if ([failedUUIDs containsObject:playlist.playlistUUID]) {
            [protectedNames addObject:foobarName];
            continue;
        }
        NSArray<JLTidalTrack *> *tracks = allTracks[playlist.playlistUUID] ?: @[];
        // nil foobarTrackIDs = playlist absent -> Create; else diff sets
        NSSet<NSString *> *foobarTrackIDs = nil;
        if (countsByName[foobarName] != nil) {
            foobarTrackIDs = localTrackIDsByName[foobarName] ?: [NSSet set];
        }
        [changes addObject:[JLTidalSyncPlanner pullChangeForName:foobarName
                                                            uuid:playlist.playlistUUID
                                                     tidalTracks:tracks
                                                  foobarTrackIDs:foobarTrackIDs]];
    }

    // Favorite tracks (skipped entirely when the fetch failed)
    NSString *favName = [JLTidalSyncPlanner favoriteTracksName];
    if (favTracksError) {
        [protectedNames addObject:favName];
    } else {
        NSNumber *existing = countsByName[favName];
        NSInteger existingCount = existing ? existing.integerValue : -1;
        [changes addObject:[JLTidalSyncPlanner favoritesPullChangeForName:favName
                                                                     uuid:@"__favorites__"
                                                               tidalCount:favTracks.count
                                                            existingCount:existingCount]];
    }

    // Favorite albums (skipped entirely when the fetch failed)
    if (!favAlbumsError) {
        for (JLTidalAlbum *album in favAlbums) {
            NSString *albumName = [JLTidalSyncPlanner favoriteAlbumNameForTitle:album.title];
            [changes addObject:[JLTidalSyncPlanner favoriteAlbumPullChangeForAlbum:album
                                                                            exists:(countsByName[albumName] != nil)]];
        }
    }

    // Check for foobar playlists that no longer exist on Tidal. Names whose
    // remote state is unknown (failed fetches) are never proposed for delete.
    NSMutableSet<NSString *> *knownRemoteNames =
        [NSMutableSet setWithArray:[changes valueForKey:@"playlistName"]];
    [knownRemoteNames unionSet:protectedNames];
    NSString *albumNamePrefix = [JLTidalSyncPlanner favoriteAlbumNameForTitle:@""];
    NSDictionary<NSString *, NSString *> *nameToUUIDSnapshot = [self snapshotNameToUUIDMap];

    for (NSString *foobarName in countsByName) {
        if (![self isTidalSyncedName:foobarName]) continue;
        if ([knownRemoteNames containsObject:foobarName]) continue;
        // With the album list unfetched, any album playlist may still exist
        // remotely - do not propose deleting it.
        if (favAlbumsError && [foobarName hasPrefix:albumNamePrefix]) continue;
        [changes addObject:[[JLTidalSyncChange alloc]
            initWithType:JLTidalSyncChangeTypeDelete
                    name:foobarName
             tracksAdded:0
           tracksRemoved:countsByName[foobarName].integerValue
               tidalUUID:nameToUUIDSnapshot[foobarName]]];
    }

    // Cache for apply phase (successful fetches only - apply can never
    // touch a playlist whose remote state is unknown)
    NSMutableDictionary *cached = [allTracks mutableCopy];
    if (!favTracksError) {
        cached[@"__favorites__"] = favTracks;
    }
    self.cachedPlaylistTracks = [cached copy];
    self.cachedPlaylists = [playlistMap copy];
    self.cachedFolderPaths = [playlistFolderPaths copy];

    NSUInteger excluded = failedUUIDs.count + (favTracksError ? 1 : 0) + (favAlbumsError ? 1 : 0);
    if (excluded > 0) {
        tidal::logError([[NSString stringWithFormat:
            @"PlaylistSync: preview excluded %lu collection(s) whose fetch failed; "
            @"they will not be modified or deleted",
            (unsigned long)excluded] UTF8String]);
    }

    JLTidalSyncReport *report = [[JLTidalSyncReport alloc] initWithChanges:changes];
    tidal::logInfo([[NSString stringWithFormat:@"PlaylistSync: preview complete - %@",
                     [report summary]] UTF8String]);
    completion(report, nil);
}

#pragma mark - Pull from Tidal (Apply)

- (void)applyPullWithReport:(JLTidalSyncReport *)report
                 completion:(void (^)(BOOL, NSError *))completion {
    tidal::logInfo("PlaylistSync: applying pull from Tidal");

    // Imports are asynchronous; the group keeps the completion honest by
    // holding it until every one of them has landed. The counter turns a
    // silent partial failure into a reported one.
    dispatch_group_t importGroup = dispatch_group_create();
    auto failureCount = std::make_shared<std::atomic<int>>(0);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        fb2k::inMainThread([self, report, completion, importGroup, failureCount]() {
            auto pm = playlist_manager::get();

            for (JLTidalSyncChange *change in report.changes) {
                switch (change.changeType) {
                    case JLTidalSyncChangeTypeCreate: {
                        pfc::string8 name([change.playlistName UTF8String]);
                        t_size newIdx = pm->create_playlist(name, name.length(), SIZE_MAX);

                        if (newIdx != SIZE_MAX) {
                            NSArray<JLTidalTrack *> *tracks = self.cachedPlaylistTracks[change.tidalUUID];
                            if (tracks.count > 0) {
                                [self addTracks:tracks toPlaylistIndex:newIdx
                                    importGroup:importGroup failureCount:failureCount.get()];
                            }
                            // Install sync lock
                            tidal::installSyncLock(newIdx);
                            // Update mapping (stateQueue-confined)
                            if (change.tidalUUID) {
                                dispatch_sync(self.stateQueue, ^{
                                    self.uuidToNameMap[change.tidalUUID] = change.playlistName;
                                    self.nameToUUIDMap[change.playlistName] = change.tidalUUID;
                                });
                            }
                        }
                        break;
                    }

                    case JLTidalSyncChangeTypeUpdate: {
                        pfc::string8 name([change.playlistName UTF8String]);
                        t_size idx = pm->find_playlist(name, name.length());
                        if (idx != SIZE_MAX) {
                            // Clear and re-add all tracks (simple full sync)
                            pm->playlist_clear(idx);
                            NSArray<JLTidalTrack *> *tracks = self.cachedPlaylistTracks[change.tidalUUID];
                            if (tracks.count > 0) {
                                [self addTracks:tracks toPlaylistIndex:idx
                                    importGroup:importGroup failureCount:failureCount.get()];
                            }
                        }
                        break;
                    }

                    case JLTidalSyncChangeTypeDelete: {
                        pfc::string8 name([change.playlistName UTF8String]);
                        t_size idx = pm->find_playlist(name, name.length());
                        BOOL removed = NO;
                        if (idx != SIZE_MAX) {
                            // Our own lock blocks playlist removal, so this
                            // call quietly failed while the mapping was dropped
                            // anyway -- the Delete was then re-proposed on every
                            // later pull, and push saw an unmapped playlist and
                            // created a remote duplicate.
                            tidal::removeSyncLock(idx);
                            removed = pm->remove_playlist(idx);
                            if (!removed) {
                                tidal::logError([[NSString stringWithFormat:
                                    @"Could not remove playlist \"%@\"; keeping its mapping",
                                    change.playlistName] UTF8String]);
                            }
                        } else {
                            removed = YES;  // already gone locally
                        }

                        // Drop the mapping only when the playlist is really gone.
                        if (removed) {
                            dispatch_sync(self.stateQueue, ^{
                                if (change.tidalUUID) {
                                    [self.uuidToNameMap removeObjectForKey:change.tidalUUID];
                                }
                                [self.nameToUUIDMap removeObjectForKey:change.playlistName];
                            });
                        }
                        break;
                    }

                    case JLTidalSyncChangeTypeUnchanged:
                        break;
                }
            }

            // Handle favorite albums that need track fetching, then wait for
            // every queued import before telling the caller we are done.
            [self fetchAndApplyFavoriteAlbums:report
                                  importGroup:importGroup
                                 failureCount:failureCount.get()
                                   completion:^(BOOL ok, NSError *error) {
                dispatch_group_notify(importGroup,
                                      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    int failures = failureCount->load();
                    if (failures > 0) {
                        tidal::logError([[NSString stringWithFormat:
                            @"PlaylistSync: pull finished with %d failed import(s)", failures] UTF8String]);
                        completion(NO, error ?: JLTidalError(JLTidalErrorInternal,
                            [NSString stringWithFormat:@"%d playlist import(s) failed", failures]));
                        return;
                    }
                    completion(ok, error);
                });
            }];
        });
    });
}

#pragma mark - Push to Tidal (Preview)

- (void)previewPushToTidalWithCompletion:(JLTidalSyncPreviewCompletion)completion {
    tidal::logInfo("PlaylistSync: previewing push to Tidal");

    // First, get current Tidal state (paginated - full list or error)
    [[JLTidalAPI shared] getUserPlaylistsWithCompletion:^(NSArray<JLTidalPlaylist *> *tidalPlaylists, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        // Snapshot fb2k playlist names/counts on the main thread
        // (playlist_manager is main-thread-only per fb2k SDK), then plan
        // off-main on the snapshot.
        fb2k::inMainThread([self, tidalPlaylists, completion]() {
            NSMutableArray<NSString *> *localNames = [NSMutableArray array];
            NSMutableArray<NSNumber *> *localCounts = [NSMutableArray array];
            auto pm = playlist_manager::get();
            t_size count = pm->get_playlist_count();
            for (t_size i = 0; i < count; i++) {
                pfc::string8 name;
                pm->playlist_get_name(i, name);
                [localNames addObject:[NSString stringWithUTF8String:name.c_str()]];
                [localCounts addObject:@((NSInteger)pm->playlist_get_item_count(i))];
            }

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSMutableArray<JLTidalSyncChange *> *changes = [NSMutableArray array];
                NSSet<NSString *> *tidalUUIDs = [NSSet setWithArray:[tidalPlaylists valueForKey:@"playlistUUID"]];
                NSDictionary<NSString *, NSString *> *nameToUUID = [self snapshotNameToUUIDMap];

                for (NSUInteger i = 0; i < localNames.count; i++) {
                    NSString *foobarName = localNames[i];
                    if ([JLTidalSyncPlanner shouldSkipPushForName:foobarName]) continue;

                    [changes addObject:[JLTidalSyncPlanner pushChangeForName:foobarName
                                                                        uuid:nameToUUID[foobarName]
                                                             knownTidalUUIDs:tidalUUIDs
                                                                   itemCount:localCounts[i].integerValue]];
                }

                JLTidalSyncReport *report = [[JLTidalSyncReport alloc] initWithChanges:changes];
                tidal::logInfo([[NSString stringWithFormat:@"PlaylistSync: push preview - %@",
                                 [report summary]] UTF8String]);
                completion(report, nil);
            });
        });
    }];
}

#pragma mark - Push to Tidal (Apply)

- (void)applyPushWithReport:(JLTidalSyncReport *)report
                 completion:(void (^)(BOOL, NSError *))completion {
    tidal::logInfo("PlaylistSync: applying push to Tidal");

    dispatch_group_t group = dispatch_group_create();
    // firstError and the uuid/name maps are only touched on stateQueue -
    // completion handlers arrive concurrently from the URL session.
    __block NSError *firstError = nil;

    for (JLTidalSyncChange *change in report.changes) {
        if (change.changeType == JLTidalSyncChangeTypeCreate) {
            dispatch_group_enter(group);
            NSString *title = [self tidalTitleFromFoobarName:change.playlistName];

            [[JLTidalAPI shared] createPlaylistWithTitle:title
                                            description:nil
                                             completion:^(JLTidalPlaylist *playlist, NSError *error) {
                if (error) {
                    dispatch_sync(self.stateQueue, ^{
                        if (!firstError) firstError = error;
                    });
                    dispatch_group_leave(group);
                    return;
                }

                // Record the mapping as soon as the remote playlist exists.
                // Deferring it until after the tracks were added meant that any
                // failure in between -- most realistically a 429 on the ETag
                // probe -- left an empty playlist on the TIDAL account with no
                // local mapping, so the next push created another one.
                if (playlist.playlistUUID) {
                    dispatch_sync(self.stateQueue, ^{
                        self.uuidToNameMap[playlist.playlistUUID] = change.playlistName;
                        self.nameToUUIDMap[change.playlistName] = playlist.playlistUUID;
                    });
                }

                // Add tracks from foobar playlist (with ISRC resolution)
                [self resolveTidalTrackIDsFromFoobarPlaylist:change.playlistName
                                                 completion:^(NSArray<NSString *> *trackIDs) {
                    if (trackIDs.count > 0 && playlist.playlistUUID) {
                        // Get ETag first
                        [[JLTidalAPI shared] getPlaylistETagForID:playlist.playlistUUID
                                                      completion:^(NSString *etag, NSError *etagError) {
                            if (etag) {
                                [[JLTidalAPI shared] addTrackIDs:trackIDs
                                                   toPlaylistID:playlist.playlistUUID
                                                           etag:etag
                                                     completion:^(BOOL success, NSError *addError) {
                                    dispatch_sync(self.stateQueue, ^{
                                        if (addError && !firstError) firstError = addError;
                                    });
                                    // Mappings are persisted once, after the group completes
                                    dispatch_group_leave(group);
                                }];
                            } else {
                                // The playlist was created but its tracks were
                                // not added. Reporting success here is what made
                                // "Push complete" appear over an empty remote
                                // playlist.
                                tidal::logError([[NSString stringWithFormat:
                                    @"Push: created \"%@\" but could not read its ETag: %@",
                                    change.playlistName,
                                    etagError.localizedDescription ?: @"no ETag in response"] UTF8String]);
                                dispatch_sync(self.stateQueue, ^{
                                    if (!firstError) {
                                        firstError = etagError ?: JLTidalError(JLTidalErrorInvalidResponse,
                                            @"Playlist created but its ETag could not be read");
                                    }
                                });
                                dispatch_group_leave(group);
                            }
                        }];
                    } else {
                        dispatch_group_leave(group);
                    }
                }];
            }];
        } else if (change.changeType == JLTidalSyncChangeTypeUpdate && change.tidalUUID) {
            dispatch_group_enter(group);
            // For update, we need to get current Tidal tracks, diff, and apply
            [self pushTrackChangesForPlaylist:change.playlistName
                                   tidalUUID:change.tidalUUID
                                  completion:^(NSError *error) {
                if (error) {
                    dispatch_sync(self.stateQueue, ^{
                        if (!firstError) firstError = error;
                    });
                }
                dispatch_group_leave(group);
            }];
        }
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        __block NSError *pushError = nil;
        dispatch_sync(self.stateQueue, ^{
            pushError = firstError;
        });
        if (pushError) {
            tidal::logError([[NSString stringWithFormat:@"PlaylistSync: push failed: %@",
                              pushError.localizedDescription] UTF8String]);
            completion(NO, pushError);
        } else {
            dispatch_async(self.stateQueue, ^{
                [self saveMappings];
            });
            tidal::logInfo("PlaylistSync: push complete");
            completion(YES, nil);
        }
    });
}

#pragma mark - Helpers

/// Playlist identity that survives the wait for an async import.
///
/// process_locations_async returns immediately, and applyPull goes on to
/// delete playlists in the same loop -- every removal shifts the indices
/// above it. A captured index therefore names a different playlist by the
/// time the import lands: tracks were dropped by the bounds check, or worse,
/// appended to whichever playlist had slid into that slot. A GUID names the
/// same playlist or nothing at all.
static GUID capturePlaylistGUID(t_size playlistIdx) {
    playlist_manager_v5::ptr pm5;
    if (playlist_manager_v5::tryGet(pm5)) {
        return pm5->playlist_get_guid(playlistIdx);
    }
    return pfc::guid_null;  // pre-2.0 host: fall back to the index
}

/// Re-resolve at completion time. Returns SIZE_MAX when the playlist is gone,
/// which the caller must treat as "drop these tracks", not "use index 0".
static t_size resolvePlaylistIndex(const GUID &guid, t_size fallbackIdx) {
    playlist_manager_v5::ptr pm5;
    if (playlist_manager_v5::tryGet(pm5) && guid != pfc::guid_null) {
        return pm5->find_playlist_by_guid(guid);
    }
    return fallbackIdx;
}

/// Notify class for async track import during sync.
///
/// Imports are network-bound and land long after applyPull's loop returns, so
/// the caller has to be able to wait for them: reporting "Pull complete" over
/// still-empty playlists let a second preview taken inside that window snapshot
/// them as empty, plan an Update, and double every track when both imports
/// landed. The group is left exactly once, on either outcome.
class TidalSyncImportNotify : public process_locations_notify {
public:
    GUID m_playlistGUID;
    t_size m_playlistIndex;  // fallback only, for hosts without playlist_manager_v5
    pfc::string_list_impl m_paths;
    dispatch_group_t m_group;
    std::atomic<int> *m_failureCount;

    TidalSyncImportNotify(GUID playlistGUID, t_size playlistIndex,
                          dispatch_group_t group, std::atomic<int> *failureCount)
        : m_playlistGUID(playlistGUID), m_playlistIndex(playlistIndex),
          m_group(group), m_failureCount(failureCount) {}

    void on_completion(metadb_handle_list_cref items) override {
        if (items.get_count() > 0) {
            auto pm = playlist_manager::get();
            t_size idx = resolvePlaylistIndex(m_playlistGUID, m_playlistIndex);
            if (idx < pm->get_playlist_count()) {
                pm->playlist_undo_backup(idx);
                pfc::bit_array_false noSelect;
                pm->playlist_insert_items(idx, SIZE_MAX, items, noSelect);
            } else {
                tidal::logError("Sync import: target playlist no longer exists, tracks dropped");
                if (m_failureCount) m_failureCount->fetch_add(1);
            }
        } else if (m_paths.get_count() > 0) {
            tidal::logError("Sync import: no items resolved from the requested locations");
            if (m_failureCount) m_failureCount->fetch_add(1);
        }
        finish();
    }

    void on_aborted() override {
        tidal::logError("Sync import aborted");
        if (m_failureCount) m_failureCount->fetch_add(1);
        finish();
    }

private:
    std::atomic<bool> m_finished{false};
    void finish() {
        if (m_group && !m_finished.exchange(true)) dispatch_group_leave(m_group);
    }
};

- (void)addTracks:(NSArray<JLTidalTrack *> *)tracks
  toPlaylistIndex:(t_size)playlistIdx
     importGroup:(dispatch_group_t)importGroup
    failureCount:(std::atomic<int> *)failureCount {
    if (tracks.count == 0) return;

    // fb2k opens an info reader per imported location. Without this, a pull of
    // N tracks issues N authenticated GETs from the loader thread for metadata
    // we already hold fully parsed.
    [[JLTidalStreamResolver shared] seedMetadataForTracks:tracks];

    if (importGroup) dispatch_group_enter(importGroup);
    auto notify = new service_impl_t<TidalSyncImportNotify>(
        capturePlaylistGUID(playlistIdx), playlistIdx, importGroup, failureCount);
    for (JLTidalTrack *track in tracks) {
        NSString *url = [NSString stringWithFormat:@"tidal://track/%@", track.trackID];
        notify->m_paths.add_item([url UTF8String]);
    }

    pfc::list_t<const char*> pathPtrs;
    for (t_size i = 0; i < notify->m_paths.get_count(); i++) {
        pathPtrs.add_item(notify->m_paths[i]);
    }

    playlist_incoming_item_filter_v2::get()->process_locations_async(
        pathPtrs,
        playlist_incoming_item_filter_v2::op_flag_no_filter |
        playlist_incoming_item_filter_v2::op_flag_delay_ui,
        nullptr, nullptr, nullptr,
        notify
    );
}

// Thread-safe read of the name -> UUID mapping for off-main planning.
- (NSDictionary<NSString *, NSString *> *)snapshotNameToUUIDMap {
    __block NSDictionary<NSString *, NSString *> *snapshot = nil;
    dispatch_sync(self.stateQueue, ^{
        snapshot = [self.nameToUUIDMap copy];
    });
    return snapshot;
}

// Main-thread-only: reads playlist items via playlist_manager.
- (NSSet<NSString *> *)trackIDSetFromPlaylist:(t_size)playlistIdx count:(t_size)count {
    NSMutableSet *set = [NSMutableSet setWithCapacity:count];
    auto pm = playlist_manager::get();

    for (t_size i = 0; i < count; i++) {
        @autoreleasepool {
            metadb_handle_ptr handle = pm->playlist_get_item_handle(playlistIdx, i);
            if (handle.is_valid()) {
                const char *path = handle->get_path();
                auto parsed = tidal::parseURL(std::string(path));
                if (parsed.has_value() && parsed->type == tidal::TidalContentType::Track) {
                    [set addObject:[NSString stringWithUTF8String:parsed->id.c_str()]];
                }
            }
        }
    }
    return set;
}

/// Resolve track IDs with ISRC fallback for non-tidal tracks.
/// Collects tidal:// track IDs directly, then looks up ISRC for local files.
/// Playlist reads happen on the main thread (playlist_manager is
/// main-thread-only per fb2k SDK); ISRC lookups run off-main with bounded
/// concurrency, deduplicated so each ISRC is looked up once.
- (void)resolveTidalTrackIDsFromFoobarPlaylist:(NSString *)foobarName
                                    completion:(void (^)(NSArray<NSString *> *trackIDs))completion {
    fb2k::inMainThread([self, foobarName, completion]() {
        auto pm = playlist_manager::get();
        pfc::string8 name([foobarName UTF8String]);
        t_size idx = pm->find_playlist(name, name.length());
        if (idx == SIZE_MAX) {
            completion(@[]);
            return;
        }

        NSMutableArray<NSString *> *resolvedIDs = [NSMutableArray array];
        NSMutableArray<NSString *> *uniqueISRCs = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *isrcPositions =
            [NSMutableDictionary dictionary];

        t_size count = pm->playlist_get_item_count(idx);
        for (t_size i = 0; i < count; i++) {
            @autoreleasepool {
                metadb_handle_ptr handle = pm->playlist_get_item_handle(idx, i);
                if (!handle.is_valid()) {
                    [resolvedIDs addObject:@""];  // placeholder
                    continue;
                }

                const char *path = handle->get_path();
                auto parsed = tidal::parseURL(std::string(path));
                if (parsed.has_value() && parsed->type == tidal::TidalContentType::Track) {
                    [resolvedIDs addObject:[NSString stringWithUTF8String:parsed->id.c_str()]];
                    continue;
                }

                // Non-tidal track - try to get ISRC
                [resolvedIDs addObject:@""];  // placeholder, may be filled by ISRC lookup

                metadb_info_container::ptr info;
                if (handle->get_info_ref(info)) {
                    const char *isrc = info->info().meta_get("ISRC", 0);
                    if (isrc && strlen(isrc) > 0) {
                        NSString *isrcStr = [NSString stringWithUTF8String:isrc];
                        NSMutableArray<NSNumber *> *positions = isrcPositions[isrcStr];
                        if (!positions) {
                            positions = [NSMutableArray array];
                            isrcPositions[isrcStr] = positions;
                            [uniqueISRCs addObject:isrcStr];
                        }
                        [positions addObject:@(resolvedIDs.count - 1)];
                        tidal::logDebug([[NSString stringWithFormat:@"PlaylistSync: found ISRC %@ for local track %s",
                                          isrcStr, path] UTF8String]);
                    } else {
                        tidal::logDebug([[NSString stringWithFormat:@"PlaylistSync: no ISRC for local track %s, skipping", path] UTF8String]);
                    }
                }
            }
        }

        if (uniqueISRCs.count == 0) {
            // No ISRC lookups needed, filter out empty placeholders
            NSMutableArray<NSString *> *filtered = [NSMutableArray array];
            for (NSString *trackID in resolvedIDs) {
                if (trackID.length > 0) [filtered addObject:trackID];
            }
            completion([filtered copy]);
            return;
        }

        // Resolve unique ISRCs via API off-main with bounded concurrency;
        // each result fans out to every position sharing that ISRC.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            dispatch_group_t group = dispatch_group_create();
            dispatch_queue_t isrcWriteQueue = dispatch_queue_create("com.foobar2000.tidal.sync.isrcwrite", DISPATCH_QUEUE_SERIAL);
            // Completions run on the URL session's queue, so signaling there
            // cannot deadlock this loop (which runs on a global queue thread).
            dispatch_semaphore_t lookupSlots = dispatch_semaphore_create(4);

            for (NSString *isrc in uniqueISRCs) {
                dispatch_semaphore_wait(lookupSlots, DISPATCH_TIME_FOREVER);
                dispatch_group_enter(group);
                [[JLTidalAPI shared] getTrackByISRC:isrc completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
                    if (tracks.count > 0) {
                        dispatch_sync(isrcWriteQueue, ^{
                            for (NSNumber *pos in isrcPositions[isrc]) {
                                resolvedIDs[pos.unsignedIntegerValue] = tracks.firstObject.trackID;
                            }
                        });
                        tidal::logDebug([[NSString stringWithFormat:@"PlaylistSync: ISRC %@ resolved to track %@",
                                          isrc, tracks.firstObject.trackID] UTF8String]);
                    } else {
                        tidal::logDebug([[NSString stringWithFormat:@"PlaylistSync: ISRC %@ not found on TIDAL",
                                          isrc] UTF8String]);
                    }
                    dispatch_semaphore_signal(lookupSlots);
                    dispatch_group_leave(group);
                }];
            }

            dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSMutableArray<NSString *> *filtered = [NSMutableArray array];
                for (NSString *trackID in resolvedIDs) {
                    if (trackID.length > 0) [filtered addObject:trackID];
                }
                tidal::logInfo([[NSString stringWithFormat:@"PlaylistSync: resolved %lu/%lu tracks (including %lu unique ISRC lookups)",
                                  (unsigned long)filtered.count, (unsigned long)resolvedIDs.count,
                                  (unsigned long)uniqueISRCs.count] UTF8String]);
                completion([filtered copy]);
            });
        });
    });
}

- (void)fetchAndApplyFavoriteAlbums:(JLTidalSyncReport *)report
                        importGroup:(dispatch_group_t)importGroup
                       failureCount:(std::atomic<int> *)failureCount
                         completion:(void (^)(BOOL, NSError *))completion {
    // Find album changes that need track fetching
    NSMutableArray<JLTidalSyncChange *> *albumChanges = [NSMutableArray array];
    for (JLTidalSyncChange *change in report.changes) {
        if (change.changeType == JLTidalSyncChangeTypeCreate &&
            [change.tidalUUID hasPrefix:@"__favalbum_"]) {
            [albumChanges addObject:change];
        }
    }

    if (albumChanges.count == 0) {
        dispatch_async(self.stateQueue, ^{
            [self saveMappings];
        });
        completion(YES, nil);
        return;
    }

    dispatch_group_t group = dispatch_group_create();

    for (JLTidalSyncChange *change in albumChanges) {
        NSString *albumID = [JLTidalSyncPlanner albumIDFromFavoriteAlbumKey:change.tidalUUID];

        dispatch_group_enter(group);
        [[JLTidalAPI shared] getAlbumTracksForAlbumID:albumID completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
            if (tracks.count > 0) {
                fb2k::inMainThread([self, change, tracks, importGroup, failureCount]() {
                    auto pm = playlist_manager::get();
                    pfc::string8 name([change.playlistName UTF8String]);
                    t_size idx = pm->find_playlist(name, name.length());
                    if (idx != SIZE_MAX) {
                        [self addTracks:tracks toPlaylistIndex:idx
                            importGroup:importGroup failureCount:failureCount];
                    }
                });
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        dispatch_async(self.stateQueue, ^{
            [self saveMappings];
        });
        completion(YES, nil);
    });
}

- (void)pushTrackChangesForPlaylist:(NSString *)foobarName
                          tidalUUID:(NSString *)uuid
                         completion:(void (^)(NSError *))completion {
    // Get Tidal's current tracks (all pages, so the diff sees tracks 201+)
    [[JLTidalAPI shared] getAllPlaylistTracksForPlaylistID:uuid
                                                completion:^(NSArray<JLTidalTrack *> *tidalTracks, NSError *error) {
        if (error) {
            completion(error);
            return;
        }

        // Resolve local tracks with ISRC matching
        [self resolveTidalTrackIDsFromFoobarPlaylist:foobarName completion:^(NSArray<NSString *> *localTrackIDs) {
            NSArray<NSString *> *toAdd =
                [JLTidalSyncPlanner trackIDsToAddFromLocalIDs:localTrackIDs tidalTracks:tidalTracks];

            if (toAdd.count == 0) {
                completion(nil);
                return;
            }

            // Get ETag, then add tracks
            [[JLTidalAPI shared] getPlaylistETagForID:uuid completion:^(NSString *etag, NSError *etagError) {
                if (etagError || !etag) {
                    completion(etagError);
                    return;
                }

                [[JLTidalAPI shared] addTrackIDs:toAdd
                                   toPlaylistID:uuid
                                           etag:etag
                                     completion:^(BOOL success, NSError *addError) {
                    completion(addError);
                }];
            }];
        }];
    }];
}

#pragma mark - Persistence

// Call only from stateQueue (or during single-threaded init) so map reads
// and the file write never race concurrent mutations.
- (void)saveMappings {
    NSMutableDictionary *combined = [NSMutableDictionary dictionary];
    combined[@"uuidToName"] = [self.uuidToNameMap copy];
    combined[@"nameToUUID"] = [self.nameToUUIDMap copy];

    NSError *archiveError = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:combined
                                         requiringSecureCoding:YES
                                                        error:&archiveError];
    if (archiveError) {
        tidal::logError([[NSString stringWithFormat:@"PlaylistSync: failed to archive mappings: %@",
                          archiveError.localizedDescription] UTF8String]);
    }
    if (data) {
        NSString *path = [self mappingFilePath];
        NSError *writeError = nil;
        if (![data writeToURL:[NSURL fileURLWithPath:path]
                      options:NSDataWritingAtomic
                        error:&writeError]) {
            tidal::logError([[NSString stringWithFormat:@"PlaylistSync: failed to write mappings: %@",
                              writeError.localizedDescription] UTF8String]);
        }
    }
}

- (void)loadMappings {
    NSString *path = [self mappingFilePath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;

    NSError *unarchiveError = nil;
    NSSet *allowedClasses = [NSSet setWithObjects:
                             [NSDictionary class], [NSMutableDictionary class], [NSString class], nil];
    NSDictionary *combined = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses
                                                                fromData:data
                                                                   error:&unarchiveError];
    if (unarchiveError) {
        tidal::logError([[NSString stringWithFormat:@"PlaylistSync: failed to load mappings: %@",
                          unarchiveError.localizedDescription] UTF8String]);
        return;
    }
    if (combined) {
        NSDictionary *u2n = combined[@"uuidToName"];
        NSDictionary *n2u = combined[@"nameToUUID"];
        if (u2n) [self.uuidToNameMap addEntriesFromDictionary:u2n];
        if (n2u) [self.nameToUUIDMap addEntriesFromDictionary:n2u];
    }
}

- (NSString *)mappingFilePath {
    // The fb2k v2 profile is ~/Library/foobar2000-v2, not
    // ~/Library/Application Support/foobar2000-v2. Storing the mapping in the
    // wrong tree meant it did not travel with a copied or restored profile --
    // and because pull records a mapping only on Create, a lost entry never
    // comes back: every pull then reports Unchanged while every push proposes
    // a full remote duplicate.
    NSString *library = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    NSString *profileDir = [library stringByAppendingPathComponent:@"foobar2000-v2"];
    NSString *profilePath = [profileDir stringByAppendingPathComponent:@"tidal_sync_map.plist"];

    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:profilePath]) return profilePath;

    // One-time migration from the old Application Support location.
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *legacyPath = [[appSupport stringByAppendingPathComponent:@"foobar2000-v2"]
                            stringByAppendingPathComponent:@"tidal_sync_map.plist"];
    if ([fm fileExistsAtPath:legacyPath]) {
        NSError *error = nil;
        [fm createDirectoryAtPath:profileDir withIntermediateDirectories:YES
                       attributes:nil error:nil];
        if ([fm copyItemAtPath:legacyPath toPath:profilePath error:&error]) {
            tidal::logInfo("PlaylistSync: migrated sync map into the foobar2000 profile");
        } else {
            tidal::logError([[NSString stringWithFormat:
                @"PlaylistSync: could not migrate sync map (%@); using the old location",
                error.localizedDescription ?: @"unknown error"] UTF8String]);
            return legacyPath;
        }
    }
    return profilePath;
}

@end
