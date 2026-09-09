//
//  ArtistGalleryData.h
//  foo_jl_biography_mac
//
//  Container for artist gallery images - fetched separately from biography
//

#pragma once

#import <Foundation/Foundation.h>
#import "ArtistImage.h"

NS_ASSUME_NONNULL_BEGIN

@class ArtistGalleryDataBuilder;

#pragma mark - ArtistGalleryData

/// Immutable container for artist gallery images
/// Fetched independently from biography data to allow parallel loading
@interface ArtistGalleryData : NSObject <NSSecureCoding>

/// Artist name this gallery belongs to
@property (nonatomic, copy, readonly) NSString *artistName;

/// MusicBrainz ID used for FanartTV lookup (may be nil if unavailable)
@property (nonatomic, copy, readonly, nullable) NSString *mbid;

/// Array of artist images from all sources, sorted by preference
@property (nonatomic, copy, readonly) NSArray<ArtistImage *> *images;

/// When this gallery data was fetched
@property (nonatomic, strong, readonly) NSDate *fetchedAt;

/// Whether the gallery has no images (true if 0 images from all sources)
@property (nonatomic, assign, readonly) BOOL isEmpty;

/// Whether this data was loaded from cache
@property (nonatomic, assign, readonly) BOOL isFromCache;

/// Whether cache data is stale (past 24hr TTL but still usable)
@property (nonatomic, assign, readonly) BOOL isStale;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithBuilder:(ArtistGalleryDataBuilder *)builder NS_DESIGNATED_INITIALIZER;

/// Number of images in the gallery
@property (nonatomic, assign, readonly) NSUInteger imageCount;

/// Get images of a specific type
- (NSArray<ArtistImage *> *)imagesOfType:(ArtistImageType)type;

/// Get images from a specific source
- (NSArray<ArtistImage *> *)imagesFromSource:(BiographySource)source;

@end

#pragma mark - ArtistGalleryDataBuilder

/// Builder for constructing ArtistGalleryData
@interface ArtistGalleryDataBuilder : NSObject

@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy, nullable) NSString *mbid;
@property (nonatomic, copy) NSArray<ArtistImage *> *images;
@property (nonatomic, strong, nullable) NSDate *fetchedAt;
@property (nonatomic, assign) BOOL isFromCache;
@property (nonatomic, assign) BOOL isStale;

- (instancetype)initWithArtistName:(NSString *)artistName;
- (ArtistGalleryData *)build;

/// Add images from a source, handling merge and deduplication
- (void)addImages:(NSArray<ArtistImage *> *)images;

/// Sort images by source priority (FanartTV first), likes, then type
- (void)sortImagesByPreference;

@end

NS_ASSUME_NONNULL_END
