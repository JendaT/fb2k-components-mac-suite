//
//  TidalPlaylistSync.mm
//  foo_jl_tidal_mac
//
//  Bidirectional playlist sync between Tidal and foobar2000
//

#import "TidalPlaylistSync.h"
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
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *uuidToNameMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *nameToUUIDMap;

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
    __block NSError *firstError = nil;

    // Fetch playlists
    dispatch_group_enter(group);
    [[JLTidalAPI shared] getUserPlaylistsWithCompletion:^(NSArray<JLTidalPlaylist *> *result, NSError *error) {
        if (error && !firstError) firstError = error;
        playlists = result ?: @[];
        dispatch_group_leave(group);
    }];

    // Fetch folders (v2 - may fail)
    dispatch_group_enter(group);
    [[JLTidalAPI shared] getPlaylistFoldersWithCompletion:^(NSArray<JLTidalPlaylistFolder *> *result, NSError *error) {
        if (error) {
            tidal::logDebug([[NSString stringWithFormat:@"PlaylistSync: folder fetch failed (will use flat structure): %@",
                              error.localizedDescription] UTF8String]);
        }
        folders = result ?: @[];
        dispatch_group_leave(group);
    }];

    // Fetch favorite tracks
    dispatch_group_enter(group);
    [[JLTidalAPI shared] getFavoriteTracksWithLimit:200 offset:0 completion:^(NSArray<JLTidalTrack *> *result, NSError *error) {
        favTracks = result ?: @[];
        dispatch_group_leave(group);
    }];

    // Fetch favorite albums
    dispatch_group_enter(group);
    [[JLTidalAPI shared] getFavoriteAlbumsWithLimit:100 offset:0 completion:^(NSArray<JLTidalAlbum *> *result, NSError *error) {
        favAlbums = result ?: @[];
        dispatch_group_leave(group);
    }];

    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (firstError) {
            completion(nil, firstError);
            return;
        }

        // Build folder path mapping and UUID -> folder path mapping
        NSDictionary<NSString *, NSString *> *folderPaths =
            [JLTidalSyncPlanner folderPathsForFolders:folders];
        NSDictionary<NSString *, NSString *> *playlistFolderPaths =
            [JLTidalSyncPlanner playlistFolderPathsForFolders:folders folderPaths:folderPaths];

        // Fetch tracks for each playlist
        dispatch_group_t tracksGroup = dispatch_group_create();
        NSMutableDictionary<NSString *, NSArray<JLTidalTrack *> *> *allTracks = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, JLTidalPlaylist *> *playlistMap = [NSMutableDictionary dictionary];
        dispatch_queue_t writeQueue = dispatch_queue_create("com.foobar2000.tidal.sync.trackwrite", DISPATCH_QUEUE_SERIAL);

        for (JLTidalPlaylist *playlist in playlists) {
            playlistMap[playlist.playlistUUID] = playlist;
            dispatch_group_enter(tracksGroup);
            [[JLTidalAPI shared] getPlaylistTracksForPlaylistID:playlist.playlistUUID
                                                          limit:200
                                                         offset:0
                                                     completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
                dispatch_sync(writeQueue, ^{
                    allTracks[playlist.playlistUUID] = tracks ?: @[];
                });
                dispatch_group_leave(tracksGroup);
            }];
        }

        dispatch_group_notify(tracksGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

        // Cache for apply phase
        self.cachedPlaylistTracks = [allTracks copy];
        self.cachedPlaylists = [playlistMap copy];
        self.cachedFolderPaths = [playlistFolderPaths copy];

        // Build change report
        NSMutableArray<JLTidalSyncChange *> *changes = [NSMutableArray array];

        // Check each Tidal playlist against foobar state
        for (JLTidalPlaylist *playlist in playlists) {
            NSString *folderPath = playlistFolderPaths[playlist.playlistUUID];
            NSString *foobarName = [self foobarNameForPlaylist:playlist folderPath:folderPath];
            NSArray<JLTidalTrack *> *tracks = allTracks[playlist.playlistUUID] ?: @[];

            auto pm = playlist_manager::get();
            pfc::string8 nameStr([foobarName UTF8String]);
            t_size existingIdx = pm->find_playlist(nameStr, nameStr.length());

            // nil foobarTrackIDs = playlist absent -> Create; else diff sets
            NSSet<NSString *> *foobarTrackIDs = nil;
            if (existingIdx != SIZE_MAX) {
                t_size existingCount = pm->playlist_get_item_count(existingIdx);
                foobarTrackIDs = [self trackIDSetFromPlaylist:existingIdx count:existingCount];
            }
            [changes addObject:[JLTidalSyncPlanner pullChangeForName:foobarName
                                                                uuid:playlist.playlistUUID
                                                         tidalTracks:tracks
                                                      foobarTrackIDs:foobarTrackIDs]];
        }

        // Check for favorite tracks
        {
            NSString *favName = [JLTidalSyncPlanner favoriteTracksName];
            auto pm = playlist_manager::get();
            pfc::string8 nameStr([favName UTF8String]);
            t_size existingIdx = pm->find_playlist(nameStr, nameStr.length());
            NSInteger existingCount = (existingIdx == SIZE_MAX)
                ? -1 : (NSInteger)pm->playlist_get_item_count(existingIdx);

            [changes addObject:[JLTidalSyncPlanner favoritesPullChangeForName:favName
                                                                         uuid:@"__favorites__"
                                                                   tidalCount:favTracks.count
                                                                existingCount:existingCount]];

            // Store fav tracks for apply
            NSMutableDictionary *cachedCopy = [self.cachedPlaylistTracks mutableCopy];
            cachedCopy[@"__favorites__"] = favTracks;
            self.cachedPlaylistTracks = [cachedCopy copy];
        }

        // Check for favorite albums
        for (JLTidalAlbum *album in favAlbums) {
            NSString *albumName = [JLTidalSyncPlanner favoriteAlbumNameForTitle:album.title];
            auto pm = playlist_manager::get();
            pfc::string8 nameStr([albumName UTF8String]);
            t_size existingIdx = pm->find_playlist(nameStr, nameStr.length());

            [changes addObject:[JLTidalSyncPlanner favoriteAlbumPullChangeForAlbum:album
                                                                            exists:(existingIdx != SIZE_MAX)]];
        }

        // Check for foobar playlists that no longer exist on Tidal
        NSSet<NSString *> *tidalNames = [NSSet setWithArray:[changes valueForKey:@"playlistName"]];
        auto pm = playlist_manager::get();
        t_size count = pm->get_playlist_count();
        for (t_size i = 0; i < count; i++) {
            pfc::string8 name;
            pm->playlist_get_name(i, name);
            NSString *foobarName = [NSString stringWithUTF8String:name.c_str()];
            if ([self isTidalSyncedName:foobarName] && ![tidalNames containsObject:foobarName]) {
                [changes addObject:[[JLTidalSyncChange alloc]
                    initWithType:JLTidalSyncChangeTypeDelete
                            name:foobarName
                     tracksAdded:0
                   tracksRemoved:pm->playlist_get_item_count(i)
                       tidalUUID:self.nameToUUIDMap[foobarName]]];
            }
        }

        JLTidalSyncReport *report = [[JLTidalSyncReport alloc] initWithChanges:changes];
        tidal::logInfo([[NSString stringWithFormat:@"PlaylistSync: preview complete - %@",
                         [report summary]] UTF8String]);
        completion(report, nil);

        }); // end dispatch_group_notify(tracksGroup)
    });
}

#pragma mark - Pull from Tidal (Apply)

- (void)applyPullWithReport:(JLTidalSyncReport *)report
                 completion:(void (^)(BOOL, NSError *))completion {
    tidal::logInfo("PlaylistSync: applying pull from Tidal");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        fb2k::inMainThread([self, report, completion]() {
            auto pm = playlist_manager::get();

            for (JLTidalSyncChange *change in report.changes) {
                switch (change.changeType) {
                    case JLTidalSyncChangeTypeCreate: {
                        pfc::string8 name([change.playlistName UTF8String]);
                        t_size newIdx = pm->create_playlist(name, name.length(), SIZE_MAX);

                        if (newIdx != SIZE_MAX) {
                            NSArray<JLTidalTrack *> *tracks = self.cachedPlaylistTracks[change.tidalUUID];
                            if (tracks.count > 0) {
                                [self addTracks:tracks toPlaylistIndex:newIdx];
                            }
                            // Install sync lock
                            tidal::installSyncLock(newIdx);
                            // Update mapping
                            if (change.tidalUUID) {
                                self.uuidToNameMap[change.tidalUUID] = change.playlistName;
                                self.nameToUUIDMap[change.playlistName] = change.tidalUUID;
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
                                [self addTracks:tracks toPlaylistIndex:idx];
                            }
                        }
                        break;
                    }

                    case JLTidalSyncChangeTypeDelete: {
                        pfc::string8 name([change.playlistName UTF8String]);
                        t_size idx = pm->find_playlist(name, name.length());
                        if (idx != SIZE_MAX) {
                            pm->remove_playlist(idx);
                        }
                        // Remove mapping
                        if (change.tidalUUID) {
                            [self.uuidToNameMap removeObjectForKey:change.tidalUUID];
                        }
                        [self.nameToUUIDMap removeObjectForKey:change.playlistName];
                        break;
                    }

                    case JLTidalSyncChangeTypeUnchanged:
                        break;
                }
            }

            // Handle favorite albums that need track fetching
            [self fetchAndApplyFavoriteAlbums:report completion:completion];
        });
    });
}

#pragma mark - Push to Tidal (Preview)

- (void)previewPushToTidalWithCompletion:(JLTidalSyncPreviewCompletion)completion {
    tidal::logInfo("PlaylistSync: previewing push to Tidal");

    // First, get current Tidal state
    [[JLTidalAPI shared] getUserPlaylistsWithCompletion:^(NSArray<JLTidalPlaylist *> *tidalPlaylists, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableArray<JLTidalSyncChange *> *changes = [NSMutableArray array];
            NSSet<NSString *> *tidalUUIDs = [NSSet setWithArray:[tidalPlaylists valueForKey:@"playlistUUID"]];

            auto pm = playlist_manager::get();
            t_size count = pm->get_playlist_count();

            for (t_size i = 0; i < count; i++) {
                pfc::string8 name;
                pm->playlist_get_name(i, name);
                NSString *foobarName = [NSString stringWithUTF8String:name.c_str()];

                if ([JLTidalSyncPlanner shouldSkipPushForName:foobarName]) continue;

                NSString *uuid = self.nameToUUIDMap[foobarName];
                [changes addObject:[JLTidalSyncPlanner pushChangeForName:foobarName
                                                                    uuid:uuid
                                                         knownTidalUUIDs:tidalUUIDs
                                                               itemCount:pm->playlist_get_item_count(i)]];
            }

            JLTidalSyncReport *report = [[JLTidalSyncReport alloc] initWithChanges:changes];
            tidal::logInfo([[NSString stringWithFormat:@"PlaylistSync: push preview - %@",
                             [report summary]] UTF8String]);
            completion(report, nil);
        });
    }];
}

#pragma mark - Push to Tidal (Apply)

- (void)applyPushWithReport:(JLTidalSyncReport *)report
                 completion:(void (^)(BOOL, NSError *))completion {
    tidal::logInfo("PlaylistSync: applying push to Tidal");

    dispatch_group_t group = dispatch_group_create();
    __block NSError *firstError = nil;

    for (JLTidalSyncChange *change in report.changes) {
        if (change.changeType == JLTidalSyncChangeTypeCreate) {
            dispatch_group_enter(group);
            NSString *title = [self tidalTitleFromFoobarName:change.playlistName];

            [[JLTidalAPI shared] createPlaylistWithTitle:title
                                            description:nil
                                             completion:^(JLTidalPlaylist *playlist, NSError *error) {
                if (error) {
                    if (!firstError) firstError = error;
                    dispatch_group_leave(group);
                    return;
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
                                    if (addError && !firstError) firstError = addError;
                                    self.uuidToNameMap[playlist.playlistUUID] = change.playlistName;
                                    self.nameToUUIDMap[change.playlistName] = playlist.playlistUUID;
                                    // Mappings are persisted once, after the group completes
                                    dispatch_group_leave(group);
                                }];
                            } else {
                                dispatch_group_leave(group);
                            }
                        }];
                    } else {
                        if (playlist.playlistUUID) {
                            self.uuidToNameMap[playlist.playlistUUID] = change.playlistName;
                            self.nameToUUIDMap[change.playlistName] = playlist.playlistUUID;
                            // Mappings are persisted once, after the group completes
                        }
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
                if (error && !firstError) firstError = error;
                dispatch_group_leave(group);
            }];
        }
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (firstError) {
            tidal::logError([[NSString stringWithFormat:@"PlaylistSync: push failed: %@",
                              firstError.localizedDescription] UTF8String]);
            completion(NO, firstError);
        } else {
            [self saveMappings];
            tidal::logInfo("PlaylistSync: push complete");
            completion(YES, nil);
        }
    });
}

#pragma mark - Helpers

/// Notify class for async track import during sync
class TidalSyncImportNotify : public process_locations_notify {
public:
    t_size m_playlistIndex;
    pfc::string_list_impl m_paths;

    TidalSyncImportNotify(t_size playlistIndex)
        : m_playlistIndex(playlistIndex) {}

    void on_completion(metadb_handle_list_cref items) override {
        if (items.get_count() > 0) {
            auto pm = playlist_manager::get();
            if (m_playlistIndex < pm->get_playlist_count()) {
                pm->playlist_undo_backup(m_playlistIndex);
                pfc::bit_array_false noSelect;
                pm->playlist_insert_items(m_playlistIndex, SIZE_MAX, items, noSelect);
            }
        }
    }

    void on_aborted() override {}
};

- (void)addTracks:(NSArray<JLTidalTrack *> *)tracks toPlaylistIndex:(t_size)playlistIdx {
    if (tracks.count == 0) return;

    auto notify = new service_impl_t<TidalSyncImportNotify>(playlistIdx);
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
- (void)resolveTidalTrackIDsFromFoobarPlaylist:(NSString *)foobarName
                                    completion:(void (^)(NSArray<NSString *> *trackIDs))completion {
    auto pm = playlist_manager::get();
    pfc::string8 name([foobarName UTF8String]);
    t_size idx = pm->find_playlist(name, name.length());
    if (idx == SIZE_MAX) {
        completion(@[]);
        return;
    }

    NSMutableArray<NSString *> *resolvedIDs = [NSMutableArray array];
    NSMutableArray<NSString *> *isrcsToResolve = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *isrcPositions = [NSMutableDictionary dictionary];

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
                    [isrcsToResolve addObject:isrcStr];
                    isrcPositions[isrcStr] = @(resolvedIDs.count - 1);
                    tidal::logDebug([[NSString stringWithFormat:@"PlaylistSync: found ISRC %@ for local track %s",
                                      isrcStr, path] UTF8String]);
                } else {
                    tidal::logDebug([[NSString stringWithFormat:@"PlaylistSync: no ISRC for local track %s, skipping", path] UTF8String]);
                }
            }
        }
    }

    if (isrcsToResolve.count == 0) {
        // No ISRC lookups needed, filter out empty placeholders
        NSMutableArray<NSString *> *filtered = [NSMutableArray array];
        for (NSString *trackID in resolvedIDs) {
            if (trackID.length > 0) [filtered addObject:trackID];
        }
        completion([filtered copy]);
        return;
    }

    // Resolve ISRCs via API
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t isrcWriteQueue = dispatch_queue_create("com.foobar2000.tidal.sync.isrcwrite", DISPATCH_QUEUE_SERIAL);

    for (NSString *isrc in isrcsToResolve) {
        dispatch_group_enter(group);
        [[JLTidalAPI shared] getTrackByISRC:isrc completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
            if (tracks.count > 0) {
                NSNumber *pos = isrcPositions[isrc];
                if (pos) {
                    dispatch_sync(isrcWriteQueue, ^{
                        resolvedIDs[pos.unsignedIntegerValue] = tracks.firstObject.trackID;
                    });
                    tidal::logDebug([[NSString stringWithFormat:@"PlaylistSync: ISRC %@ resolved to track %@",
                                      isrc, tracks.firstObject.trackID] UTF8String]);
                }
            } else {
                tidal::logDebug([[NSString stringWithFormat:@"PlaylistSync: ISRC %@ not found on TIDAL",
                                  isrc] UTF8String]);
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray<NSString *> *filtered = [NSMutableArray array];
        for (NSString *trackID in resolvedIDs) {
            if (trackID.length > 0) [filtered addObject:trackID];
        }
        tidal::logInfo([[NSString stringWithFormat:@"PlaylistSync: resolved %lu/%lu tracks (including %lu ISRC lookups)",
                          (unsigned long)filtered.count, (unsigned long)resolvedIDs.count,
                          (unsigned long)isrcsToResolve.count] UTF8String]);
        completion([filtered copy]);
    });
}

- (void)fetchAndApplyFavoriteAlbums:(JLTidalSyncReport *)report
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
        [self saveMappings];
        completion(YES, nil);
        return;
    }

    dispatch_group_t group = dispatch_group_create();

    for (JLTidalSyncChange *change in albumChanges) {
        NSString *albumID = [JLTidalSyncPlanner albumIDFromFavoriteAlbumKey:change.tidalUUID];

        dispatch_group_enter(group);
        [[JLTidalAPI shared] getAlbumTracksForAlbumID:albumID completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
            if (tracks.count > 0) {
                fb2k::inMainThread([self, change, tracks]() {
                    auto pm = playlist_manager::get();
                    pfc::string8 name([change.playlistName UTF8String]);
                    t_size idx = pm->find_playlist(name, name.length());
                    if (idx != SIZE_MAX) {
                        [self addTracks:tracks toPlaylistIndex:idx];
                    }
                });
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self saveMappings];
        completion(YES, nil);
    });
}

- (void)pushTrackChangesForPlaylist:(NSString *)foobarName
                          tidalUUID:(NSString *)uuid
                         completion:(void (^)(NSError *))completion {
    // Get Tidal's current tracks
    [[JLTidalAPI shared] getPlaylistTracksForPlaylistID:uuid limit:200 offset:0
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
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [appSupport stringByAppendingPathComponent:@"foobar2000-v2"];
    return [dir stringByAppendingPathComponent:@"tidal_sync_map.plist"];
}

@end
