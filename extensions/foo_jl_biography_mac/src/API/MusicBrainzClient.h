//
//  MusicBrainzClient.h
//  foo_jl_biography_mac
//
//  MusicBrainz ws/2 client: resolves artist names to MBIDs and MBIDs to
//  Wikidata entity IDs. No API key required; strict 1 req/s rate limit.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class BiographyRequest;

/// Error domain for MusicBrainz errors
extern NSString * const MusicBrainzErrorDomain;

typedef NS_ENUM(NSInteger, MusicBrainzErrorCode) {
    MusicBrainzErrorCodeUnknown = 0,
    MusicBrainzErrorCodeNetworkError = 1,
    MusicBrainzErrorCodeInvalidResponse = 2,
    MusicBrainzErrorCodeNotFound = 3,
    MusicBrainzErrorCodeRateLimited = 4,
    MusicBrainzErrorCodeCancelled = 5,
};

/// Completion with the resolved MBID (nil when no confident match exists)
typedef void (^MusicBrainzMBIDCompletion)(NSString * _Nullable mbid, NSError * _Nullable error);

/// Completion with the Wikidata QID (e.g. "Q11647"; nil when the artist has none)
typedef void (^MusicBrainzQIDCompletion)(NSString * _Nullable qid, NSError * _Nullable error);

@interface MusicBrainzClient : NSObject

+ (instancetype)shared;

/// Search for an artist by name and return the best-match MBID.
/// Only high-score results whose name matches the request are accepted.
- (void)lookupMBIDForArtist:(NSString *)artistName
                      token:(BiographyRequest *)token
                 completion:(MusicBrainzMBIDCompletion)completion;

/// Look up an artist by MBID with url-rels and return its Wikidata QID.
- (void)lookupWikidataQIDForMBID:(NSString *)mbid
                           token:(BiographyRequest *)token
                      completion:(MusicBrainzQIDCompletion)completion;

/// Cancel all pending requests
- (void)cancelAllRequests;

@end

NS_ASSUME_NONNULL_END
