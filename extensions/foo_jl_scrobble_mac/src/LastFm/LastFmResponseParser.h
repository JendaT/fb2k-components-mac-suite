//
//  LastFmResponseParser.h
//  foo_jl_scrobble_mac
//
//  Pure parsing of Last.fm API JSON responses (already deserialized to
//  Foundation collections). Handles the API's polymorphic quirks --
//  single items returned as objects instead of arrays, counts as strings,
//  optional @attr blocks. No network, no state; every method is a pure
//  function of the response dictionary and unit-testable.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class TopAlbum;

@interface LastFmResponseParser : NSObject

/// track.scrobble: accepted/ignored counts from scrobbles.@attr
/// (both 0 when the response shape is unexpected)
+ (void)scrobbleResponse:(NSDictionary *)response
                accepted:(NSInteger *)accepted
                 ignored:(NSInteger *)ignored;

/// track.updateNowPlaying: whether the API confirmed the update
+ (BOOL)nowPlayingConfirmedInResponse:(NSDictionary *)response;

/// auth.getToken: the request token, or nil
+ (nullable NSString *)tokenFromResponse:(NSDictionary *)response;

/// user.getInfo: account name, or nil
+ (nullable NSString *)usernameFromUserInfoResponse:(NSDictionary *)response;

/// user.getInfo: profile image URL, preferring extralarge over large
+ (nullable NSURL *)userImageURLFromUserInfoResponse:(NSDictionary *)response;

/// user.getRecentTracks: track dictionaries, normalizing the
/// single-track-as-object quirk to an array
+ (NSArray<NSDictionary *> *)recentTrackDictsFromResponse:(NSDictionary *)response;

/// user.getRecentTracks: totalPages from @attr pagination (0 if absent)
+ (NSInteger)totalPagesFromRecentTracksResponse:(NSDictionary *)response;

/// user.getRecentTracks: total track count from @attr pagination (0 if absent)
+ (NSInteger)totalFromRecentTracksResponse:(NSDictionary *)response;

/// Whether any of the track dicts is a real scrobble (not a now-playing entry)
+ (BOOL)containsActualScrobbles:(NSArray<NSDictionary *> *)trackDicts;

/// user.getTopAlbums / getTopArtists / getTopTracks: parsed items.
/// rootKey/itemKey name the response nesting (e.g. "topalbums"/"album").
/// When asArtists is YES, each item's artist is set to its own name.
+ (NSArray<TopAlbum *> *)topItemsFromResponse:(NSDictionary *)response
                                      rootKey:(NSString *)rootKey
                                      itemKey:(NSString *)itemKey
                                    asArtists:(BOOL)asArtists;

/// album.getInfo: best cover image URL, or nil
+ (nullable NSURL *)albumImageURLFromAlbumInfoResponse:(NSDictionary *)response;

/// track.getInfo: album title and best cover image URL (either may be nil)
+ (void)trackInfoFromResponse:(NSDictionary *)response
                    albumName:(NSString *_Nullable *_Nonnull)albumName
                     imageURL:(NSURL *_Nullable *_Nonnull)imageURL;

@end

NS_ASSUME_NONNULL_END
