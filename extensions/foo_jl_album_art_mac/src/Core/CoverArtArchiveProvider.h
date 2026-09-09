//
//  CoverArtArchiveProvider.h
//  foo_jl_album_art_mac
//
//  Cover Art Archive provider - fetches artwork by MusicBrainz Release ID
//  Primary source for high-quality, multi-type artwork
//

#pragma once

#import <Foundation/Foundation.h>
#import "ArtworkSourceProvider.h"

NS_ASSUME_NONNULL_BEGIN

/// Cover Art Archive provider
/// Uses MBID from MusicBrainz to fetch artwork
/// No rate limiting required for CAA
@interface CoverArtArchiveProvider : ArtworkSourceProviderBase

/// Shared instance
@property (class, readonly, strong) CoverArtArchiveProvider *sharedInstance;

/// Fetch artwork for a specific MusicBrainz Release ID
/// @param mbid MusicBrainz Release ID (UUID format)
/// @param completion Called with results or error
- (void)searchWithMBID:(NSString *)mbid
            completion:(ArtworkSearchCompletion)completion;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
