//
//  DeezerClient.h
//  foo_jl_biography_mac
//
//  Deezer API client for artist images
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class BiographyRequest;
@class ArtistImage;

typedef void (^DeezerImageCompletion)(NSArray<ArtistImage *> * _Nullable images, NSError * _Nullable error);

/// Client for fetching artist images from Deezer
/// No authentication required for basic search
@interface DeezerClient : NSObject

+ (instancetype)shared;

/// Search for artist and return their images
/// @param artistName Artist name to search for
/// @param token Cancellation token
/// @param completion Called with array of ArtistImage or error
- (void)fetchImagesForArtist:(NSString *)artistName
                       token:(BiographyRequest *)token
                  completion:(DeezerImageCompletion)completion;

/// Cancel all in-flight requests
- (void)cancelAllRequests;

@end

NS_ASSUME_NONNULL_END
