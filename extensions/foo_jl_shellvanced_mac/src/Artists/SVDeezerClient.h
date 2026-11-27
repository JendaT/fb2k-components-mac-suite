//
//  SVDeezerClient.h
//  foo_jl_shellvanced_mac
//
//  Minimal Deezer client for artist photos (adapted from the Biography
//  component's DeezerClient). Objective-C++ header: import from .mm only.
//  Only artist names and Deezer ids ever leave the machine; requests go to
//  api.deezer.com and Deezer's image CDN, throttled to 8 requests/second.
//

#pragma once

#import <Foundation/Foundation.h>
#include <vector>

#include "DeezerMatchCore.h"

NS_ASSUME_NONNULL_BEGIN

@interface SVDeezerClient : NSObject

+ (instancetype)shared;

/// search/artist?q=&limit=5. `ok` is NO on network/quota/parse failure
/// (do not cache that as "no result"); YES with an empty vector = genuinely none.
- (void)searchArtist:(NSString *)name
          completion:(void (^)(std::vector<deezermatch::Candidate> candidates, BOOL ok))completion;

/// artist/{id}/albums?limit=100. `titles` is nil on failure.
- (void)albumTitlesForArtistId:(NSString *)artistId
                    completion:(void (^)(NSArray<NSString *> *_Nullable titles))completion;

/// artist/{id}: nb_album. completion gets -1 on failure.
- (void)albumCountForArtistId:(NSString *)artistId completion:(void (^)(long count))completion;

/// Downloads an image from Deezer's CDN (https, *.dzcdn.net only). nil on failure.
- (void)downloadImageAtURL:(NSURL *)url completion:(void (^)(NSData *_Nullable data))completion;

@end

NS_ASSUME_NONNULL_END
