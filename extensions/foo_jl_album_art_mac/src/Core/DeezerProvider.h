//
//  DeezerProvider.h
//  foo_jl_album_art_mac
//
//  Deezer API provider for front cover artwork
//  No authentication required, XL images (1000px)
//

#pragma once

#import <Foundation/Foundation.h>
#import "ArtworkSourceProvider.h"

NS_ASSUME_NONNULL_BEGIN

/// Deezer API provider
/// Returns front cover artwork only, up to 1000x1000
@interface DeezerProvider : ArtworkSourceProviderBase

/// Shared instance
@property (class, readonly, strong) DeezerProvider *sharedInstance;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
