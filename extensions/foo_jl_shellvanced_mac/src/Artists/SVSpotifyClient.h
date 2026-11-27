//
//  SVSpotifyClient.h
//  foo_jl_shellvanced_mac
//
//  Optional Spotify artist-photo source (client-credentials flow). Objective-C++ header: import
//  from .mm only. Only artist names and Spotify ids ever leave the machine.
//
//  Rate limiting is deliberately conservative (a dev app was once blocked for 24 h after ~70
//  quick searches): ONE serialized queue, >= 2.0 s between requests, and on HTTP 429 the
//  Retry-After block is persisted (spotify-block.json in the artist cache dir) and all Spotify
//  use stops until it passes.
//

#pragma once

#import <Foundation/Foundation.h>
#include <vector>

#include "SpotifyMatchCore.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SVSpotifyStatus) {
    SVSpotifyStatusOK = 0,
    SVSpotifyStatusFailed,      // network / server / parse problem: retry later
    SVSpotifyStatusBlocked,     // rate-limited (429); persisted until Retry-After passes
    SVSpotifyStatusAuthFailed,  // credentials rejected; disabled until credentials change
};

@interface SVSpotifyClient : NSObject

+ (instancetype)shared;

/// Credentials stored, not rate-limit blocked, and not rejected. Thread-safe, no network.
@property (nonatomic, readonly) BOOL isAvailable;
@property (nonatomic, readonly) BOOL isBlocked;

/// Completions run on the client's private queue (not main).
- (void)searchArtist:(NSString *)name
          completion:(void (^)(std::vector<spmatch::Candidate> candidates, SVSpotifyStatus status))completion;

/// Album titles (up to 2 pages of 50) and the endpoint's `total`.
- (void)albumsForArtistId:(NSString *)artistId
               completion:(void (^)(NSArray<NSString *> *_Nullable titles, long total, SVSpotifyStatus status))completion;

/// Spotify image CDN (https, *.scdn.co only; no token, not counted against the API queue).
- (void)downloadImageAtURL:(NSURL *)url completion:(void (^)(NSData *_Nullable data))completion;

/// Fetches a token with the given values (nothing is stored). `message` is "OK" or an error text.
- (void)testClientId:(NSString *)clientId secret:(NSString *)secret
          completion:(void (^)(BOOL ok, NSString *message))completion;

/// Drops the cached token, the auth-failed flag and the persisted rate-limit block.
- (void)credentialsChanged;

@end

NS_ASSUME_NONNULL_END
