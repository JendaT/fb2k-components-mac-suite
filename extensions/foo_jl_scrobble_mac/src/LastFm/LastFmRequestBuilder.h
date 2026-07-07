//
//  LastFmRequestBuilder.h
//  foo_jl_scrobble_mac
//
//  Pure request construction for the Last.fm API: signing, encoding, and
//  parameter assembly. No network, no singletons, no SecretConfig -- the
//  API secret and session key are passed in, so every method is a pure
//  function of its arguments and unit-testable.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ScrobbleTrack;

@interface LastFmRequestBuilder : NSObject

/// api_sig for a request: keys sorted alphabetically (excluding "format"
/// and "callback"), concatenated as key1value1key2value2...secret, MD5'd.
+ (NSString *)signatureForParameters:(NSDictionary<NSString *, NSString *> *)params
                              secret:(NSString *)secret;

/// Percent-encode for form bodies; also escapes & = + # beyond the
/// URL-query-allowed set
+ (NSString *)urlEncode:(NSString *)string;

/// application/x-www-form-urlencoded body from a parameter dictionary
+ (NSString *)postBodyFromParameters:(NSDictionary<NSString *, NSString *> *)params;

/// Parameters for track.updateNowPlaying (optional fields included only
/// when present)
+ (NSDictionary<NSString *, NSString *> *)nowPlayingParamsForTrack:(ScrobbleTrack *)track
                                                        sessionKey:(NSString *)sessionKey;

/// Parameters for track.scrobble with indexed artist[i]/track[i]/... keys.
/// Caller is responsible for capping the batch size.
+ (NSDictionary<NSString *, NSString *> *)scrobbleParamsForTracks:(NSArray<ScrobbleTrack *> *)tracks
                                                       sessionKey:(NSString *)sessionKey;

@end

NS_ASSUME_NONNULL_END
