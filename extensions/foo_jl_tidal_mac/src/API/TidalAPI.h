//
//  TidalAPI.h
//  foo_jl_tidal_mac
//
//  HTTP client for Tidal API requests
//

#pragma once

#import <Foundation/Foundation.h>
#import "TidalSession.h"
#import "TidalConstants.h"

NS_ASSUME_NONNULL_BEGIN

/// Device code response from OAuth device authorization
@interface JLTidalDeviceCode : NSObject
@property (nonatomic, copy, readonly) NSString *deviceCode;
@property (nonatomic, copy, readonly) NSString *userCode;
@property (nonatomic, copy, readonly) NSURL *verificationURI;
@property (nonatomic, copy, readonly, nullable) NSURL *verificationURIComplete;
@property (nonatomic, readonly) NSTimeInterval expiresIn;
@property (nonatomic, readonly) NSTimeInterval interval;

- (instancetype)initWithDeviceCode:(NSString *)deviceCode
                          userCode:(NSString *)userCode
                   verificationURI:(NSURL *)verificationURI
           verificationURIComplete:(nullable NSURL *)verificationURIComplete
                         expiresIn:(NSTimeInterval)expiresIn
                          interval:(NSTimeInterval)interval;
@end

@class JLTidalTrack;
@class JLTidalAlbum;
@class JLTidalArtist;
@class JLTidalPlaylist;
@class JLTidalPlaylistFolder;

/// Completion handlers
typedef void (^JLTidalDeviceCodeCompletion)(JLTidalDeviceCode * _Nullable deviceCode, NSError * _Nullable error);
typedef void (^JLTidalSessionCompletion)(JLTidalSession * _Nullable session, NSError * _Nullable error);
typedef void (^JLTidalDataCompletion)(NSDictionary * _Nullable json, NSError * _Nullable error);
typedef void (^JLTidalTracksCompletion)(NSArray<JLTidalTrack *> * _Nullable tracks, NSError * _Nullable error);
typedef void (^JLTidalAlbumsCompletion)(NSArray<JLTidalAlbum *> * _Nullable albums, NSError * _Nullable error);
typedef void (^JLTidalArtistsCompletion)(NSArray<JLTidalArtist *> * _Nullable artists, NSError * _Nullable error);
typedef void (^JLTidalPlaylistsCompletion)(NSArray<JLTidalPlaylist *> * _Nullable playlists, NSError * _Nullable error);
typedef void (^JLTidalPlaylistCompletion)(JLTidalPlaylist * _Nullable playlist, NSError * _Nullable error);
typedef void (^JLTidalFoldersCompletion)(NSArray<JLTidalPlaylistFolder *> * _Nullable folders, NSError * _Nullable error);
typedef void (^JLTidalBoolCompletion)(BOOL success, NSError * _Nullable error);
typedef void (^JLTidalETagCompletion)(NSString * _Nullable etag, NSError * _Nullable error);

@interface JLTidalAPI : NSObject

/// Shared API client instance
+ (instancetype)shared;

/// Current session. Readonly: JLTidalAuthService is the sole writer
/// (via -updateSession: in TidalAPIPrivate.h).
@property (atomic, strong, readonly, nullable) JLTidalSession *session;

/// Installed once by JLTidalAuthService. Invoked when a request needs a
/// token refresh (expired-session pre-check, 401 retry). Keeps the API
/// layer free of any dependency on the Services layer. The completion
/// must always be called exactly once.
@property (atomic, copy, nullable) void (^tokenRefreshHandler)(void (^completion)(BOOL success));

#pragma mark - OAuth Device Authorization

/// Request device code for OAuth flow
- (void)requestDeviceCodeWithCompletion:(JLTidalDeviceCodeCompletion)completion;

/// Poll for access token using device code
/// Returns JLTidalErrorDeviceCodePending if user hasn't approved yet
- (void)pollForTokenWithDeviceCode:(NSString *)deviceCode
                        completion:(JLTidalSessionCompletion)completion;

/// Refresh access token using refresh token
- (void)refreshTokenWithCompletion:(JLTidalSessionCompletion)completion;

#pragma mark - Track API

/// Get playback info for a track
/// Returns stream URL and manifest information
- (void)getPlaybackInfoForTrackID:(NSString *)trackID
                          quality:(JLTidalQuality)quality
                       completion:(JLTidalDataCompletion)completion;

/// Get track metadata
- (void)getTrackMetadataForTrackID:(NSString *)trackID
                        completion:(JLTidalDataCompletion)completion;

#pragma mark - Search API

/// Search for tracks
- (void)searchTracksWithQuery:(NSString *)query
                        limit:(NSInteger)limit
                       offset:(NSInteger)offset
                   completion:(JLTidalTracksCompletion)completion;

/// Search for albums
- (void)searchAlbumsWithQuery:(NSString *)query
                        limit:(NSInteger)limit
                       offset:(NSInteger)offset
                   completion:(JLTidalAlbumsCompletion)completion;

/// Search for artists
- (void)searchArtistsWithQuery:(NSString *)query
                         limit:(NSInteger)limit
                        offset:(NSInteger)offset
                    completion:(JLTidalArtistsCompletion)completion;

#pragma mark - Album API

/// Get tracks for an album (ordered by track number)
- (void)getAlbumTracksForAlbumID:(NSString *)albumID
                      completion:(JLTidalTracksCompletion)completion;

#pragma mark - Artist API

/// Get top tracks for an artist
- (void)getArtistTopTracksForArtistID:(NSString *)artistID
                                limit:(NSInteger)limit
                           completion:(JLTidalTracksCompletion)completion;

/// Get albums for an artist
- (void)getArtistAlbumsForArtistID:(NSString *)artistID
                             limit:(NSInteger)limit
                        completion:(JLTidalAlbumsCompletion)completion;

#pragma mark - Favorites API

/// Get user's favorite tracks
- (void)getFavoriteTracksWithLimit:(NSInteger)limit
                            offset:(NSInteger)offset
                        completion:(JLTidalTracksCompletion)completion;

/// Get ALL favorite tracks, paging until a short page. Fails (nil result)
/// on any page error or when the pagination ceiling is hit — never returns
/// a partial list as if complete.
- (void)getAllFavoriteTracksWithCompletion:(JLTidalTracksCompletion)completion;

/// Get user's favorite albums
- (void)getFavoriteAlbumsWithLimit:(NSInteger)limit
                            offset:(NSInteger)offset
                        completion:(JLTidalAlbumsCompletion)completion;

/// Get ALL favorite albums, paging until a short page (same failure
/// semantics as getAllFavoriteTracksWithCompletion:).
- (void)getAllFavoriteAlbumsWithCompletion:(JLTidalAlbumsCompletion)completion;

/// Add a track to favorites
- (void)addTrackToFavorites:(NSString *)trackID
                 completion:(JLTidalBoolCompletion)completion;

/// Remove a track from favorites
- (void)removeTrackFromFavorites:(NSString *)trackID
                      completion:(JLTidalBoolCompletion)completion;

#pragma mark - Playlists API

/// Get user's playlists. Pages internally until a short page, so the
/// result is always the complete list (or an error — never truncated).
- (void)getUserPlaylistsWithCompletion:(JLTidalPlaylistsCompletion)completion;

/// Get tracks for a playlist (single page)
- (void)getPlaylistTracksForPlaylistID:(NSString *)playlistUUID
                                 limit:(NSInteger)limit
                                offset:(NSInteger)offset
                            completion:(JLTidalTracksCompletion)completion;

/// Get ALL tracks for a playlist, paging until a short page (same failure
/// semantics as getAllFavoriteTracksWithCompletion:).
- (void)getAllPlaylistTracksForPlaylistID:(NSString *)playlistUUID
                               completion:(JLTidalTracksCompletion)completion;

/// Create a new playlist
- (void)createPlaylistWithTitle:(NSString *)title
                    description:(nullable NSString *)description
                     completion:(JLTidalPlaylistCompletion)completion;

/// Add tracks to a playlist (requires ETag for concurrency)
- (void)addTrackIDs:(NSArray<NSString *> *)trackIDs
       toPlaylistID:(NSString *)playlistUUID
               etag:(NSString *)etag
         completion:(JLTidalBoolCompletion)completion;

/// Remove tracks from a playlist by index (requires ETag for concurrency)
- (void)removeTrackAtIndices:(NSIndexSet *)indices
              fromPlaylistID:(NSString *)playlistUUID
                        etag:(NSString *)etag
                  completion:(JLTidalBoolCompletion)completion;

/// Delete a playlist
- (void)deletePlaylistWithID:(NSString *)playlistUUID
                  completion:(JLTidalBoolCompletion)completion;

/// Get the ETag for a playlist (needed before mutations)
- (void)getPlaylistETagForID:(NSString *)playlistUUID
                  completion:(JLTidalETagCompletion)completion;

/// Get playlist folders (v2 API)
- (void)getPlaylistFoldersWithCompletion:(JLTidalFoldersCompletion)completion;

/// Search for a track by ISRC
- (void)getTrackByISRC:(NSString *)isrc
            completion:(JLTidalTracksCompletion)completion;

#pragma mark - Generic Request

/// Make authenticated API request
- (void)requestWithURL:(NSURL *)url
                method:(NSString *)method
                  body:(nullable NSDictionary *)body
            completion:(JLTidalDataCompletion)completion;

/// Make authenticated API request with extra headers
- (void)requestWithURL:(NSURL *)url
                method:(NSString *)method
                  body:(nullable NSDictionary *)body
               headers:(nullable NSDictionary<NSString *, NSString *> *)extraHeaders
            completion:(JLTidalDataCompletion)completion;

@end

NS_ASSUME_NONNULL_END
