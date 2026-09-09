//
//  iTunesProvider.h
//  foo_jl_album_art_mac
//
//  iTunes Search API provider for front cover artwork
//  No authentication required, high resolution (1200px)
//

#pragma once

#import <Foundation/Foundation.h>
#import "ArtworkSourceProvider.h"

NS_ASSUME_NONNULL_BEGIN

/// iTunes Search API provider
/// Returns front cover artwork only, up to 1200x1200
@interface iTunesProvider : ArtworkSourceProviderBase

/// Shared instance
@property (class, readonly, strong) iTunesProvider *sharedInstance;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
