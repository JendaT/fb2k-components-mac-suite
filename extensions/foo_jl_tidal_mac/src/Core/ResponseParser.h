//
//  ResponseParser.h
//  foo_jl_tidal_mac
//
//  Pure JSON -> model parsing for Tidal API responses. Foundation-only —
//  no SDK, no network — unit-tested standalone (Tests/ResponseParserTests.mm).
//  JLTidalAPI stays a thin transport that hands response dictionaries here.
//
//  All item-list parsers accept nil/absent arrays and return an empty
//  (never nil) array, matching the previous inline-loop behavior.
//

#pragma once

#import <Foundation/Foundation.h>
#import "TidalModels.h"
#import "../API/TidalSession.h"

NS_ASSUME_NONNULL_BEGIN

/// One page of a v2 `my-collection/playlists/folders` listing.
@interface JLTidalFolderListing : NSObject
/// Folders on this page, in response order. Subfolders and playlists of
/// these folders are not part of the page; each folder is listed separately.
@property (nonatomic, copy, readonly) NSArray<JLTidalPlaylistFolder *> *folders;
/// UUIDs of the playlists on this page, in response order.
@property (nonatomic, copy, readonly) NSArray<NSString *> *playlistUUIDs;
/// Cursor for the next page; nil when this is the last page.
@property (nonatomic, copy, readonly, nullable) NSString *cursor;
/// FOLDER items without a derivable id and PLAYLIST items without a
/// derivable UUID. Such an item cannot be placed, so the caller must treat
/// the listing as incomplete.
@property (nonatomic, readonly) NSInteger malformedItemCount;

- (instancetype)initWithFolders:(NSArray<JLTidalPlaylistFolder *> *)folders
                  playlistUUIDs:(NSArray<NSString *> *)playlistUUIDs
                         cursor:(nullable NSString *)cursor
             malformedItemCount:(NSInteger)malformedItemCount;
@end

@interface JLTidalResponseParser : NSObject

/// Extract `data[].id` from a JSON:API collection document (openapi.tidal.com).
/// Non-string ids and malformed entries are skipped.
+ (NSArray<NSString *> *)trackIDsFromJSONAPIData:(nullable id)data;

#pragma mark - OAuth token responses

/// Parse a token response (device-code grant). Returns nil when
/// access_token or refresh_token is missing.
+ (nullable JLTidalSession *)sessionFromTokenResponse:(NSDictionary *)json;

/// Parse a refresh response, handling refresh-token rotation: Tidal issues
/// a new refresh token with each refresh, revoking the old one; when the
/// response carries none, the current session's token is kept. Returns nil
/// when access_token is missing.
+ (nullable JLTidalSession *)sessionFromRefreshResponse:(NSDictionary *)json
                                         currentSession:(JLTidalSession *)currentSession;

#pragma mark - Item lists

/// Plain item lists (search results, album/artist/playlist tracks).
+ (NSArray<JLTidalTrack *> *)tracksFromItems:(nullable NSArray *)items;
+ (NSArray<JLTidalAlbum *> *)albumsFromItems:(nullable NSArray *)items;
+ (NSArray<JLTidalArtist *> *)artistsFromItems:(nullable NSArray *)items;
+ (NSArray<JLTidalPlaylist *> *)playlistsFromItems:(nullable NSArray *)items;

/// Favorites and playlist-tracks responses wrap each entry in an "item"
/// key; entries without the wrapper are parsed directly.
+ (NSArray<JLTidalTrack *> *)tracksFromWrappedItems:(nullable NSArray *)items;
+ (NSArray<JLTidalAlbum *> *)albumsFromWrappedItems:(nullable NSArray *)items;

/// v2 folders listing items: keeps only entries with itemType == FOLDER
/// that carry an id (see JLTidalPlaylistFolder -initWithDictionary:).
+ (NSArray<JLTidalPlaylistFolder *> *)foldersFromItems:(nullable NSArray *)items;

/// v2 folders listing items: UUIDs of entries with itemType == PLAYLIST,
/// from `data.uuid`, else the suffix of `trn` "trn:playlist:<uuid>".
+ (NSArray<NSString *> *)playlistUUIDsFromFolderItems:(nullable NSArray *)items;

/// A whole v2 folders listing page. Returns nil when the response is not a
/// dictionary with an `items` array: an error payload must never read as an
/// empty folder.
+ (nullable JLTidalFolderListing *)folderListingFromResponse:(nullable id)json;

/// ISRC lookup goes through the search API, which returns fuzzy matches;
/// keep only tracks whose ISRC equals the requested one exactly.
+ (NSArray<JLTidalTrack *> *)tracksFromItems:(nullable NSArray *)items
                               matchingISRC:(NSString *)isrc;

@end

NS_ASSUME_NONNULL_END
