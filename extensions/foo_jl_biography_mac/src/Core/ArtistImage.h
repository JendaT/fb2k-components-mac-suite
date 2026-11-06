//
//  ArtistImage.h
//  foo_jl_biography_mac
//
//  Immutable data model for artist images from FanartTV and AudioDB
//

#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "BiographySource.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Enums

typedef NS_ENUM(NSInteger, ArtistImageType) {
    ArtistImageTypeBackground = 0,  // Full-size backgrounds
    ArtistImageTypeThumbnail,       // Profile/thumb images
    ArtistImageTypeLogo,            // Text logos
    ArtistImageTypeBanner           // Wide banners
};

#pragma mark - ArtistImage

/// Immutable data model for a single artist image
@interface ArtistImage : NSObject <NSSecureCoding>

/// Full-size image URL
@property (nonatomic, copy, readonly) NSURL *url;

/// Thumbnail/preview URL if available (may be nil, use url as fallback)
@property (nonatomic, copy, readonly, nullable) NSURL *thumbnailURL;

/// Type of image (background, thumbnail, logo, banner)
@property (nonatomic, assign, readonly) ArtistImageType imageType;

/// Source API (FanartTV or AudioDB)
@property (nonatomic, assign, readonly) BiographySource source;

/// Like count from FanartTV (0 for AudioDB)
@property (nonatomic, assign, readonly) NSInteger likes;

/// Original image size if known from API metadata
@property (nonatomic, assign, readonly) CGSize originalSize;

- (instancetype)init NS_UNAVAILABLE;

/// Designated initializer
- (instancetype)initWithURL:(NSURL *)url
               thumbnailURL:(nullable NSURL *)thumbnailURL
                  imageType:(ArtistImageType)imageType
                     source:(BiographySource)source
                      likes:(NSInteger)likes
               originalSize:(CGSize)originalSize NS_DESIGNATED_INITIALIZER;

/// Convenience initializer without size info
- (instancetype)initWithURL:(NSURL *)url
               thumbnailURL:(nullable NSURL *)thumbnailURL
                  imageType:(ArtistImageType)imageType
                     source:(BiographySource)source
                      likes:(NSInteger)likes;

/// Best URL to use for gallery thumbnails (thumbnailURL if available, else url)
- (NSURL *)bestThumbnailURL;

/// Display name for the image type
- (NSString *)imageTypeDisplayName;

@end

NS_ASSUME_NONNULL_END
