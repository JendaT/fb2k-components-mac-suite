//
//  ArtworkLightboxController.h
//  foo_jl_album_art_mac
//
//  Modal preview controller for browsing and selecting remote artwork
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "../Core/ArtworkResult.h"
#import "../Core/TrackMetadata.h"

NS_ASSUME_NONNULL_BEGIN

@class ArtworkLightboxController;

@protocol ArtworkLightboxDelegate <NSObject>
@optional
/// Called when user confirms selection with single image (legacy)
- (void)lightbox:(ArtworkLightboxController *)controller
    didSelectResult:(ArtworkResult *)result
          withImage:(NSImage *)image;

/// Called when user confirms selection with multiple images
- (void)lightbox:(ArtworkLightboxController *)controller
    didSelectResults:(NSDictionary<NSNumber *, ArtworkResult *> *)resultsByType
          withImages:(NSDictionary<NSNumber *, NSImage *> *)imagesByType;

/// Called when lightbox is dismissed without selection
- (void)lightboxDidCancel:(ArtworkLightboxController *)controller;
@end

@interface ArtworkLightboxController : NSViewController

/// Delegate for handling selection
@property (nonatomic, weak, nullable) id<ArtworkLightboxDelegate> delegate;

/// The track metadata (for display purposes)
@property (nonatomic, strong, readonly) TrackMetadata *metadata;

/// All available results
@property (nonatomic, copy, readonly) NSArray<ArtworkResult *> *allResults;

/// Currently selected result
@property (nonatomic, strong, readonly, nullable) ArtworkResult *selectedResult;

/// Currently displayed full-resolution image
@property (nonatomic, strong, readonly, nullable) NSImage *selectedImage;

/// Initialize with results and metadata
- (instancetype)initWithResults:(NSArray<ArtworkResult *> *)results
                       metadata:(TrackMetadata *)metadata
                 initialIndex:(NSInteger)initialIndex;

/// Present as a sheet on the given window
- (void)presentAsSheetOnWindow:(NSWindow *)parentWindow;

/// Present as a standalone modal window
- (void)presentAsModalWindow;

/// Dismiss the lightbox
- (void)dismiss;

/// Navigation
- (void)navigateToPrevious;
- (void)navigateToNext;

/// Filter by type (nil = show all)
- (void)filterByType:(nullable NSNumber *)type;

/// Confirm selection
- (void)confirmSelection;

@end

NS_ASSUME_NONNULL_END
