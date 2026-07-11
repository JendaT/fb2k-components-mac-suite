//
//  FanartTvClient.h
//  foo_jl_biography_mac
//
//  API client for Fanart.tv artist images
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ArtistImage;
@class BiographyRequest;

#pragma mark - Error Domain

extern NSString * const FanartTvErrorDomain;

typedef NS_ENUM(NSInteger, FanartTvErrorCode) {
    FanartTvErrorCodeUnknown = 0,
    FanartTvErrorCodeNetworkError,
    FanartTvErrorCodeInvalidResponse,
    FanartTvErrorCodeArtistNotFound,  // 404
    FanartTvErrorCodeRateLimited,     // 429
    FanartTvErrorCodeTimeout,
    FanartTvErrorCodeCancelled,
    FanartTvErrorCodeNoMBID           // MBID required but not provided
};

#pragma mark - Completion Types

typedef void (^FanartTvCompletion)(NSArray<ArtistImage *> * _Nullable images, NSError * _Nullable error);

#pragma mark - FanartTvClient

/// API client for Fanart.tv artist images
/// Requires MusicBrainz ID (MBID) for lookups
@interface FanartTvClient : NSObject

+ (instancetype)shared;

/// Fetch artist images from Fanart.tv
/// @param mbid MusicBrainz ID (required)
/// @param token Cancellation token
/// @param completion Called with array of ArtistImage or error
/// @note Returns FanartTvErrorCodeNoMBID if mbid is nil or empty
- (void)fetchImagesForMBID:(NSString *)mbid
                     token:(BiographyRequest *)token
                completion:(FanartTvCompletion)completion;

/// Cancel all pending requests
- (void)cancelAllRequests;

@end

NS_ASSUME_NONNULL_END
