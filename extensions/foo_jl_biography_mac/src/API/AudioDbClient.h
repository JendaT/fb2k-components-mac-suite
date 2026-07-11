//
//  AudioDbClient.h
//  foo_jl_biography_mac
//
//  API client for TheAudioDB artist images
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ArtistImage;
@class BiographyRequest;

#pragma mark - Error Domain

extern NSString * const AudioDbErrorDomain;

typedef NS_ENUM(NSInteger, AudioDbErrorCode) {
    AudioDbErrorCodeUnknown = 0,
    AudioDbErrorCodeNetworkError,
    AudioDbErrorCodeInvalidResponse,
    AudioDbErrorCodeArtistNotFound,
    AudioDbErrorCodeArtistMismatch,   // Returned artist doesn't match requested
    AudioDbErrorCodeRateLimited,      // 429
    AudioDbErrorCodeTimeout,
    AudioDbErrorCodeCancelled
};

#pragma mark - Completion Types

typedef void (^AudioDbCompletion)(NSArray<ArtistImage *> * _Nullable images, NSError * _Nullable error);

#pragma mark - AudioDbClient

/// API client for TheAudioDB artist images
/// Uses artist name for lookups with disambiguation validation
@interface AudioDbClient : NSObject

+ (instancetype)shared;

/// Fetch artist images from TheAudioDB
/// @param artistName Artist name to search for (required)
/// @param token Cancellation token
/// @param completion Called with array of ArtistImage or error
/// @note Validates returned artist name matches request (case-insensitive)
- (void)fetchImagesForArtist:(NSString *)artistName
                       token:(BiographyRequest *)token
                  completion:(AudioDbCompletion)completion;

/// Cancel all pending requests
- (void)cancelAllRequests;

@end

NS_ASSUME_NONNULL_END
