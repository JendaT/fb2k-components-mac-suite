//
//  LightboxWindowController.h
//  foo_jl_biography_mac
//
//  Full-screen lightbox for viewing artist images
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class ArtistImage;

/// Full-screen lightbox window for viewing artist images
/// - Dark semi-transparent background
/// - Centered image with aspect-fit
/// - Arrow key and click navigation
/// - ESC or click outside to close
@interface LightboxWindowController : NSWindowController

/// Initialize with images and starting index
- (instancetype)initWithImages:(NSArray<ArtistImage *> *)images
                  initialIndex:(NSUInteger)index;

/// Show the lightbox relative to a parent window
- (void)showRelativeToWindow:(NSWindow *)parentWindow;

/// Current image index
@property (nonatomic, assign, readonly) NSUInteger currentIndex;

/// Total number of images
@property (nonatomic, assign, readonly) NSUInteger imageCount;

/// Called when the lightbox is dismissed (for cleanup)
@property (nonatomic, copy, nullable) void (^onDismiss)(void);

/// Navigate to previous image
- (void)showPreviousImage;

/// Navigate to next image
- (void)showNextImage;

/// Close the lightbox
- (void)closeLightbox;

@end

NS_ASSUME_NONNULL_END
