//
//  ArtistImageCache.h
//  foo_jl_biography_mac
//
//  Dual-layer cache (memory + disk) for artist images
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class ArtistGalleryData;

#pragma mark - Enums

typedef NS_ENUM(NSInteger, ArtistImageCacheSize) {
    ArtistImageCacheSizeThumbnail,  // For gallery (200x160)
    ArtistImageCacheSizeFull        // For lightbox (max 2048)
};

#pragma mark - ArtistImageCache

/// Dual-layer cache for artist images
/// - Memory: NSCache with automatic eviction
/// - Disk: ~/Library/Caches/foo_jl_biography/images/
@interface ArtistImageCache : NSObject

+ (instancetype)shared;

#pragma mark - Image Cache

/// Synchronous lookup (memory + disk)
/// @param url Image URL
/// @param size Requested size
/// @return Cached image or nil if not found
- (nullable NSImage *)cachedImageForURL:(NSURL *)url size:(ArtistImageCacheSize)size;

/// Cache an image (both memory and disk)
/// @param image Image to cache
/// @param url Source URL
/// @param size Size category
- (void)cacheImage:(NSImage *)image forURL:(NSURL *)url size:(ArtistImageCacheSize)size;

/// Asynchronous load with concurrent limit (max 4)
/// Checks cache first, downloads if not cached
/// @param url Image URL to load
/// @param size Size to cache/resize to
/// @param completion Called on main thread with image or nil
- (void)loadImageFromURL:(NSURL *)url
                    size:(ArtistImageCacheSize)size
              completion:(void (^)(NSImage * _Nullable image))completion;

/// Prefetch multiple images in background
/// @param urls URLs to prefetch
/// @param size Size to cache
- (void)prefetchImages:(NSArray<NSURL *> *)urls size:(ArtistImageCacheSize)size;

/// Cancel pending downloads
- (void)cancelPendingDownloads;

#pragma mark - Gallery Data Cache (24hr TTL)

/// Get cached gallery data for artist
/// @param artistName Artist name (case-insensitive key)
/// @return Cached gallery data or nil if not found or expired
- (nullable ArtistGalleryData *)cachedGalleryDataForArtist:(NSString *)artistName;

/// Cache gallery data for artist (24hr TTL)
/// @param data Gallery data to cache
- (void)cacheGalleryData:(ArtistGalleryData *)data;

#pragma mark - Cache Management

/// Clear memory cache only
- (void)clearMemoryCache;

/// Clear disk cache (removes all cached images)
- (void)clearDiskCache;

/// Clear all caches
- (void)clearAllCaches;

/// Current cache statistics
@property (nonatomic, readonly) NSUInteger memoryCacheCount;
@property (nonatomic, readonly) NSUInteger diskCacheSize;  // bytes

@end

NS_ASSUME_NONNULL_END
