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
/// Blocked by a 429 or stopped after repeated failures (as opposed to not configured / rejected).
@property (nonatomic, readonly) BOOL isTemporarilyUnavailable;

/// All calls below are queued on ONE serialized worker. `urgent` jobs jump to the front of the queue
/// (artist page header / the most recently requested artist). Completions run on the worker (not main).
- (void)searchArtist:(NSString *)name urgent:(BOOL)urgent
          completion:(void (^)(std::vector<spmatch::Candidate> candidates, SVSpotifyStatus status))completion;

/// Album titles (up to 2 pages of 50): `allTitles` = every group, `primaryTitles` = album/single groups only.
/// `total` is the endpoint's total, -1 when unknown.
- (void)albumsForArtistId:(NSString *)artistId urgent:(BOOL)urgent
               completion:(void (^)(NSArray<NSString *> *_Nullable allTitles,
                                    NSArray<NSString *> *_Nullable primaryTitles,
                                    long total, SVSpotifyStatus status))completion;

/// Spotify image CDN (https, *.scdn.co only, redirects re-checked; no token, not on the API queue).
- (void)downloadImageAtURL:(NSURL *)url completion:(void (^)(NSData *_Nullable data))completion;

/// Fetches a token with the given values (nothing is stored); jumps to the front of the queue.
/// `message` is "OK" or an error text.
- (void)testClientId:(NSString *)clientId secret:(NSString *)secret
          completion:(void (^)(BOOL ok, NSString *message))completion;

/// Applied immediately: drops the cached token, auth-failed/session-disabled flags and bumps `generation`.
/// `clearBlock` also drops the persisted rate-limit block (only when the Client ID actually changed).
- (void)credentialsChangedClearingBlock:(BOOL)clearBlock;

/// Incremented by every credentialsChanged; pipelines started under an older value must not persist
/// Spotify negatives / cover-like files.
@property (nonatomic, readonly) NSUInteger generation;

@end

NS_ASSUME_NONNULL_END
