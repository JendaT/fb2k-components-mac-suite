//
//  LastFmBioClient.h
//  foo_jl_biography_mac
//
//  Last.fm API client for artist biography fetching
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class BiographyRequest;
@class BiographyData;

/// Error domain for Last.fm biography errors
extern NSString * const LastFmBioErrorDomain;

/// Error codes for Last.fm biography operations
typedef NS_ENUM(NSInteger, LastFmBioErrorCode) {
    LastFmBioErrorCodeUnknown = 0,
    LastFmBioErrorCodeNetworkError = 1,
    LastFmBioErrorCodeInvalidResponse = 2,
    LastFmBioErrorCodeArtistNotFound = 3,
    LastFmBioErrorCodeRateLimited = 4,
    LastFmBioErrorCodeCancelled = 5,
};

/// Completion handler for artist info request
typedef void (^LastFmArtistInfoCompletion)(NSDictionary * _Nullable response, NSError * _Nullable error);

/// Completion handler for similar artists request
typedef void (^LastFmSimilarArtistsCompletion)(NSArray * _Nullable artists, NSError * _Nullable error);

@interface LastFmBioClient : NSObject

/// Shared client instance
+ (instancetype)shared;

/// Fetch artist info from Last.fm
/// Returns biography, tags, similar artists, images, stats
/// @param artistName The artist name to look up
/// @param token Cancellation token (check isCancelled during operation)
/// @param completion Called on background thread with response or error
- (void)fetchArtistInfo:(NSString *)artistName
                  token:(BiographyRequest *)token
             completion:(LastFmArtistInfoCompletion)completion;

/// Fetch similar artists
/// @param artistName The artist name to look up
/// @param token Cancellation token
/// @param completion Called with array of similar artist dictionaries
- (void)fetchSimilarArtists:(NSString *)artistName
                      token:(BiographyRequest *)token
                 completion:(LastFmSimilarArtistsCompletion)completion;

/// Parse artist info response into BiographyData builder fields
/// @param response The JSON response from artist.getinfo
/// @return Dictionary with parsed fields (biography, tags, images, etc.)
+ (NSDictionary *)parseArtistInfoResponse:(NSDictionary *)response;

/// Cancel all pending requests
- (void)cancelAllRequests;

@end

NS_ASSUME_NONNULL_END
