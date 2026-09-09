//
//  ArtistGalleryView.h
//  foo_jl_biography_mac
//
//  Horizontal scrolling gallery view for artist images
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class ArtistImage;
@class ArtistGalleryView;

#pragma mark - Delegate

@protocol ArtistGalleryViewDelegate <NSObject>

/// Called when user clicks an image
- (void)galleryView:(ArtistGalleryView *)view didSelectImageAtIndex:(NSUInteger)index;

@end

#pragma mark - ArtistGalleryView

/// Horizontal scrolling gallery for artist images
/// - Fixed height (120px)
/// - Single row with horizontal scrolling
/// - Loading skeleton placeholders
/// - Click to select image
@interface ArtistGalleryView : NSView

@property (nonatomic, weak, nullable) id<ArtistGalleryViewDelegate> delegate;

/// Array of artist images to display
@property (nonatomic, copy, nullable) NSArray<ArtistImage *> *images;

/// Whether the view is in loading state (shows skeleton placeholders)
@property (nonatomic, assign) BOOL isLoading;

/// Height of the gallery (default 120px, 0 when no images)
@property (nonatomic, assign, readonly) CGFloat galleryHeight;

/// Update the loaded image at a specific index (after async load)
- (void)updateImageAtIndex:(NSUInteger)index withImage:(NSImage *)image;

/// Scroll to show image at index
- (void)scrollToIndex:(NSUInteger)index animated:(BOOL)animated;

/// Clear all images and reset state
- (void)clear;

@end

NS_ASSUME_NONNULL_END
