//
//  TidalPlaylistSync.h
//  foo_jl_tidal_mac
//
//  Bidirectional playlist sync between Tidal and foobar2000.
//  Uses Playlist Organizer's delimiter convention for folder hierarchy.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class JLTidalPlaylist;
@class JLTidalPlaylistFolder;
@class JLTidalTrack;

/// Delimiter matching Playlist Organizer's kPathSeparator
static NSString * const kTidalSyncDelimiter = @" \u00BB ";

/// Root prefix for all Tidal-synced playlists
static NSString * const kTidalSyncPrefix = @"TIDAL";

/// Special folder names
static NSString * const kTidalSyncFavoriteTracks = @"Favorite Tracks";
static NSString * const kTidalSyncFavoriteAlbums = @"Favorite Albums";

/// Status report entry for a single playlist change
@interface JLTidalSyncChange : NSObject
typedef NS_ENUM(NSInteger, JLTidalSyncChangeType) {
    JLTidalSyncChangeTypeCreate,      // New playlist
    JLTidalSyncChangeTypeUpdate,      // Track list changed
    JLTidalSyncChangeTypeDelete,      // Playlist removed
    JLTidalSyncChangeTypeUnchanged,   // No changes needed
};
@property (nonatomic, readonly) JLTidalSyncChangeType changeType;
@property (nonatomic, copy, readonly) NSString *playlistName;
@property (nonatomic, readonly) NSInteger tracksAdded;
@property (nonatomic, readonly) NSInteger tracksRemoved;
@property (nonatomic, copy, readonly, nullable) NSString *tidalUUID;

- (instancetype)initWithType:(JLTidalSyncChangeType)type
                        name:(NSString *)name
                 tracksAdded:(NSInteger)added
               tracksRemoved:(NSInteger)removed
                   tidalUUID:(nullable NSString *)uuid;
@end

/// Status report for a sync operation
@interface JLTidalSyncReport : NSObject
@property (nonatomic, strong, readonly) NSArray<JLTidalSyncChange *> *changes;
@property (nonatomic, readonly) NSInteger totalCreated;
@property (nonatomic, readonly) NSInteger totalUpdated;
@property (nonatomic, readonly) NSInteger totalDeleted;
@property (nonatomic, readonly) NSInteger totalUnchanged;

- (instancetype)initWithChanges:(NSArray<JLTidalSyncChange *> *)changes;
- (NSString *)summary;
@end

/// Completion handler for sync preview (before confirmation)
typedef void (^JLTidalSyncPreviewCompletion)(JLTidalSyncReport * _Nullable report, NSError * _Nullable error);

/// Playlist sync engine
@interface JLTidalPlaylistSync : NSObject

+ (instancetype)shared;

/// Preview what would change when pulling from Tidal (does not apply changes)
- (void)previewPullFromTidalWithCompletion:(JLTidalSyncPreviewCompletion)completion;

/// Apply a previously previewed pull operation
- (void)applyPullWithReport:(JLTidalSyncReport *)report
                 completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// Preview what would change when pushing to Tidal (does not apply changes)
- (void)previewPushToTidalWithCompletion:(JLTidalSyncPreviewCompletion)completion;

/// Apply a previously previewed push operation
- (void)applyPushWithReport:(JLTidalSyncReport *)report
                 completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// Build the foobar playlist name from Tidal playlist + folder path
- (NSString *)foobarNameForPlaylist:(JLTidalPlaylist *)playlist
                         folderPath:(nullable NSString *)folderPath;

/// Extract Tidal playlist title from a foobar name (strips prefix/folders)
- (nullable NSString *)tidalTitleFromFoobarName:(NSString *)foobarName;

/// Check if a foobar playlist name belongs to the TIDAL sync namespace
- (BOOL)isTidalSyncedName:(NSString *)foobarName;

/// Stored mapping: Tidal UUID -> foobar playlist name
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString *, NSString *> *uuidToNameMap;

/// Stored mapping: foobar playlist name -> Tidal UUID
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString *, NSString *> *nameToUUIDMap;

@end

NS_ASSUME_NONNULL_END
