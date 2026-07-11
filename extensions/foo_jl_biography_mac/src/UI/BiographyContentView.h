//
//  BiographyContentView.h
//  foo_jl_biography_mac
//
//  Main content view displaying biography and artist image
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class BiographyData;
@class ArtistImage;
@class ArtistGalleryView;
@class BiographyContentView;

#pragma mark - Delegate

@protocol BiographyContentViewDelegate <NSObject>
@optional

/// Called when user clicks an image in the gallery
- (void)contentView:(BiographyContentView *)contentView didSelectGalleryImageAtIndex:(NSUInteger)index;

@end

#pragma mark - BiographyContentView

@interface BiographyContentView : NSView

@property (nonatomic, weak, nullable) id<BiographyContentViewDelegate> delegate;

/// The gallery view (for external access if needed)
@property (nonatomic, strong, readonly) ArtistGalleryView *galleryView;

/// Update the view with new biography data
- (void)updateWithBiographyData:(BiographyData *)data;

/// Update gallery images (called after async image fetch)
- (void)updateGalleryImages:(NSArray<ArtistImage *> *)images;

/// Set gallery loading state
- (void)setGalleryLoading:(BOOL)loading;

/// Clear the view
- (void)clear;

@end

NS_ASSUME_NONNULL_END
