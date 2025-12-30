//
//  BiographyCache.h
//  foo_jl_biography_mac
//
//  SQLite-based cache for biography data
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class BiographyData;

@interface BiographyCache : NSObject

/// Initialize cache (creates database if needed)
- (instancetype)init;

/// Cache biography data for an artist
/// @param data The biography data to cache
/// @param artistName The artist name (key)
- (void)cacheBiography:(BiographyData *)data forArtist:(NSString *)artistName;

/// Fetch cached biography for an artist
/// @param artistName The artist name to look up
/// @return Cached data or nil if not found
- (nullable BiographyData *)fetchCachedBiographyForArtist:(NSString *)artistName;

/// Check if cached data exists and is not expired
/// @param artistName The artist name
/// @return YES if valid cache exists
- (BOOL)hasFreshCacheForArtist:(NSString *)artistName;

/// Clear cache for a specific artist
- (void)clearCacheForArtist:(NSString *)artistName;

/// Clear all cached data
- (void)clearAllCache;

/// Get total cache size in bytes
@property (nonatomic, readonly) NSUInteger totalCacheSize;

/// Enforce max cache size by removing oldest entries
- (void)enforceMaxSize;

@end

NS_ASSUME_NONNULL_END
