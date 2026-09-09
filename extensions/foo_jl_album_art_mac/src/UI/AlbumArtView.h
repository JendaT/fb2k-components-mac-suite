//
//  AlbumArtView.h
//  foo_jl_album_art_mac
//
//  Custom NSView for displaying album artwork with navigation arrows
//  and footer area for search progress/thumbnails
//

#pragma once

#import <Cocoa/Cocoa.h>

@class ArtworkResult;

NS_ASSUME_NONNULL_BEGIN

@class AlbumArtView;

/// Footer display state
typedef NS_ENUM(NSInteger, AlbumArtFooterState) {
    AlbumArtFooterStateIdle = 0,
    AlbumArtFooterStateSearching,
    AlbumArtFooterStateThumbnails,
    AlbumArtFooterStateError
};

@protocol AlbumArtViewDelegate <NSObject>
@optional
- (void)albumArtViewRequestsContextMenu:(AlbumArtView*)view atPoint:(NSPoint)point;
- (void)albumArtViewNavigatePrevious:(AlbumArtView*)view;
- (void)albumArtViewNavigateNext:(AlbumArtView*)view;

/// Called when user clicks a thumbnail in the footer
- (void)albumArtView:(AlbumArtView*)view didSelectThumbnailAtIndex:(NSInteger)index;

/// Called when user clicks Cancel in the search footer
- (void)albumArtViewDidRequestCancelSearch:(AlbumArtView*)view;
@end

@interface AlbumArtView : NSView

// Delegate for handling interactions
@property (nonatomic, weak, nullable) id<AlbumArtViewDelegate> delegate;

// The artwork image to display
@property (nonatomic, strong, nullable) NSImage *image;

// Display options
@property (nonatomic, assign) BOOL isSquare;      // Force square aspect ratio
@property (nonatomic, assign) BOOL isZoomable;    // Allow scroll/zoom (not implemented yet)

// Navigation arrows
@property (nonatomic, assign) BOOL canNavigatePrevious;  // Show left arrow
@property (nonatomic, assign) BOOL canNavigateNext;      // Show right arrow

// Current artwork type name (displayed when no image)
@property (nonatomic, copy, nullable) NSString *artworkTypeName;

#pragma mark - Footer (Search UI)

/// Current footer state
@property (nonatomic, assign) AlbumArtFooterState footerState;

/// Progress/status message for footer
@property (nonatomic, copy, nullable) NSString *footerMessage;

/// Thumbnail images for results (displayed in footer when state is Thumbnails)
@property (nonatomic, copy, nullable) NSArray<NSImage *> *footerThumbnails;

/// Artwork results (for grouping by type in display)
@property (nonatomic, copy, nullable) NSArray<ArtworkResult *> *footerResults;

/// Footer height (0 when hidden, >0 when visible)
@property (nonatomic, readonly) CGFloat footerHeight;

/// Show/hide footer with optional animation
- (void)setFooterVisible:(BOOL)visible animated:(BOOL)animated;

/// Update footer to show search progress
- (void)showSearchProgress:(NSString *)message;

/// Update footer to show thumbnails
- (void)showThumbnails:(NSArray<NSImage *> *)thumbnails results:(NSArray<ArtworkResult *> *)results;

/// Update footer to show error
- (void)showError:(NSString *)message;

/// Hide footer and reset to idle
- (void)hideFooter;

// Refresh the display
- (void)refreshDisplay;

@end

NS_ASSUME_NONNULL_END
