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

@interface JLTidalResponseParser : NSObject

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

/// v2 folders response: keeps only entries with type == FOLDER.
+ (NSArray<JLTidalPlaylistFolder *> *)foldersFromItems:(nullable NSArray *)items;

/// ISRC lookup goes through the search API, which returns fuzzy matches;
/// keep only tracks whose ISRC equals the requested one exactly.
+ (NSArray<JLTidalTrack *> *)tracksFromItems:(nullable NSArray *)items
                               matchingISRC:(NSString *)isrc;

@end

NS_ASSUME_NONNULL_END
