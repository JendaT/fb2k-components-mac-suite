//
//  MusicBrainzProvider.h
//  foo_jl_album_art_mac
//
//  MusicBrainz API provider for MBID lookup
//  Not a direct artwork source - provides MBIDs for Cover Art Archive
//

#pragma once

#import <Foundation/Foundation.h>
#import "TrackMetadata.h"

NS_ASSUME_NONNULL_BEGIN

/// Completion handler for MBID lookup
typedef void (^MusicBrainzMBIDCompletion)(NSString * _Nullable mbid, NSError * _Nullable error);

/// MusicBrainz API client for release MBID lookup
/// Strict 1 req/sec rate limiting per MusicBrainz policy
@interface MusicBrainzProvider : NSObject

/// Shared instance (singleton for rate limiting)
@property (class, readonly, strong) MusicBrainzProvider *sharedInstance;

/// Look up MusicBrainz Release ID for given metadata
/// If metadata already has an MBID, returns it directly without API call
/// @param metadata Track metadata (uses artist + album for search)
/// @param completion Called with MBID or error
- (void)lookupMBIDForMetadata:(TrackMetadata *)metadata
                   completion:(MusicBrainzMBIDCompletion)completion;

/// Cancel any in-progress lookup
- (void)cancel;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
