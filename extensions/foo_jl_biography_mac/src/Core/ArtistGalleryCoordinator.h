//
//  ArtistGalleryCoordinator.h
//  foo_jl_biography_mac
//
//  Orchestrates fetching artist images from multiple sources
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ArtistImage;
@class ArtistGalleryData;
@class ArtistGalleryCoordinator;

#pragma mark - Delegate

@protocol ArtistGalleryCoordinatorDelegate <NSObject>

/// Called when images have been fetched and are ready to display
- (void)coordinator:(ArtistGalleryCoordinator *)coordinator
    didUpdateImages:(NSArray<ArtistImage *> *)images;

/// Called when loading starts
- (void)coordinatorDidStartLoading:(ArtistGalleryCoordinator *)coordinator;

/// Called when loading finishes (success or failure)
- (void)coordinatorDidFinishLoading:(ArtistGalleryCoordinator *)coordinator;

@optional

/// Called if both APIs fail
- (void)coordinator:(ArtistGalleryCoordinator *)coordinator
   didFailWithError:(NSError *)error;

@end

#pragma mark - ArtistGalleryCoordinator

/// Coordinates fetching artist images from FanartTV and AudioDB
/// - Fetches from both sources in parallel
/// - Merges and deduplicates results
/// - Handles cancellation on artist change
/// - Caches results to disk
@interface ArtistGalleryCoordinator : NSObject

@property (nonatomic, weak, nullable) id<ArtistGalleryCoordinatorDelegate> delegate;

/// Currently loading artist name (nil if idle)
@property (nonatomic, copy, readonly, nullable) NSString *currentArtistName;

/// Whether a fetch is currently in progress
@property (nonatomic, assign, readonly) BOOL isLoading;

/// Last fetched gallery data (may be from cache)
@property (nonatomic, strong, readonly, nullable) ArtistGalleryData *galleryData;

/// Fetch images for an artist
/// @param artistName Artist name (for AudioDB and cache key)
/// @param mbid MusicBrainz ID (for FanartTV, can be nil)
/// @param fallbackImageURL Last.fm artist image URL as fallback (can be nil)
/// @note Cancels any in-flight request for a different artist
- (void)fetchImagesForArtist:(NSString *)artistName
                        mbid:(nullable NSString *)mbid
            fallbackImageURL:(nullable NSURL *)fallbackImageURL;

/// Cancel current fetch
- (void)cancelCurrentFetch;

/// Clear cache for current artist
- (void)clearCache;

/// Clear all cached gallery data
- (void)clearAllCaches;

@end

NS_ASSUME_NONNULL_END
