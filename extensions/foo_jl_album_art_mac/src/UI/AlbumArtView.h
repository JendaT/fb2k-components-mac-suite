//
//  AlbumArtView.h
//  foo_jl_album_art_mac
//
//  Custom NSView for displaying album artwork with navigation arrows
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class AlbumArtView;

@protocol AlbumArtViewDelegate <NSObject>
@optional
- (void)albumArtViewRequestsContextMenu:(AlbumArtView*)view atPoint:(NSPoint)point;
- (void)albumArtViewNavigatePrevious:(AlbumArtView*)view;
- (void)albumArtViewNavigateNext:(AlbumArtView*)view;
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

// Refresh the display
- (void)refreshDisplay;

@end

NS_ASSUME_NONNULL_END
