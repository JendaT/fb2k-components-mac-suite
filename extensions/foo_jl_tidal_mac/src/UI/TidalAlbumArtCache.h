//
//  TidalAlbumArtCache.h
//  foo_jl_tidal_mac
//
//  Async album art loading and caching for Tidal covers
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Async album art loader for Tidal content
/// Loads images from resources.tidal.com CDN
@interface JLTidalAlbumArtCache : NSObject

+ (instancetype)shared;

/// Load album art asynchronously from Tidal CDN
/// @param coverID The Tidal cover ID (e.g., "abc123-def456")
/// @param size Size in pixels (will be rounded to nearest Tidal size: 80, 160, 320, 640, 1280)
/// @param completion Called on main thread when image is ready (may be nil on failure)
- (void)loadImageForCoverID:(NSString *)coverID
                       size:(NSInteger)size
                 completion:(void (^)(NSImage * _Nullable image))completion;

/// Get cached image (returns nil if not cached)
- (nullable NSImage *)cachedImageForCoverID:(NSString *)coverID size:(NSInteger)size;

/// Check if image is being loaded
- (BOOL)isLoadingCoverID:(NSString *)coverID size:(NSInteger)size;

/// Clear all cached images
- (void)clearCache;

/// Maximum cache size in bytes (default 50MB)
@property (nonatomic, assign) NSUInteger maxCacheSize;

/// Build cover URL for a Tidal cover ID
+ (NSURL *)coverURLForCoverID:(NSString *)coverID size:(NSInteger)size;

@end

NS_ASSUME_NONNULL_END
