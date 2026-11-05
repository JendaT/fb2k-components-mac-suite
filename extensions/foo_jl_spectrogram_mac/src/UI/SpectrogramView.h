//
//  SpectrogramView.h
//  foo_jl_spectrogram_mac
//
//  Scrolling spectrogram: columns of color-mapped levels enter at the right
//  edge and move left. Frequency axis, gridlines, and the dB color scale are
//  drawn on top.
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class SpectrogramView;

@protocol SpectrogramViewDelegate <NSObject>
- (void)spectrogramViewRequestsContextMenu:(SpectrogramView *)view atPoint:(NSPoint)point;
@optional
// Sent when the view joins or leaves a window (its display link's screen changes).
- (void)spectrogramViewDidMoveToWindow:(SpectrogramView *)view;
// Sent on a double-click.
- (void)spectrogramViewRequestsFullScreenToggle:(SpectrogramView *)view;
@end

@interface SpectrogramView : NSView

@property (nonatomic, weak, nullable) id<SpectrogramViewDelegate> delegate;

// The view in the full-screen window: takes the full-screen orientation
// setting instead of the panel's. Set before the view is shown.
@property (nonatomic) BOOL fullScreen;

// Re-read display settings (colormap, axis, scale) from config.
- (void)reloadSettings;

// Pixel rows each column must have: the plot height in device pixels. Held
// at the previous value while a resize is in progress (the existing image
// stretches meanwhile), so call this every frame.
- (NSInteger)plotRows;

// Columns per point of horizontal travel (the backing scale factor).
- (CGFloat)columnsPerPoint;

// Add one column at the right edge. `levels` holds `rows` values in 0..1,
// top row (highest frequency) first. Call flushWithPhase: once per frame afterwards.
- (void)appendColumn:(const float *)levels rows:(NSInteger)rows;

// Put the columns appended since the last flush on screen, shifted left by
// `phase` columns (0..1): how far time has moved past the newest column.
// Call every frame, also when no column was added, for even motion.
- (void)flushWithPhase:(CGFloat)phase;

// Drop everything drawn so far.
- (void)clear;

@end

NS_ASSUME_NONNULL_END
