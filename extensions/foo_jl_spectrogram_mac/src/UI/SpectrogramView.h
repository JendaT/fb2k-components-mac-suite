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
@end

@interface SpectrogramView : NSView

@property (nonatomic, weak, nullable) id<SpectrogramViewDelegate> delegate;

// Re-read display settings (colormap, axis, scale) from config.
- (void)reloadSettings;

// Pixel rows each column must have: the plot height in device pixels. Held
// at the previous value while a resize is in progress (the existing image
// stretches meanwhile), so call this every frame.
- (NSInteger)plotRows;

// Columns per point of horizontal travel (the backing scale factor).
- (CGFloat)columnsPerPoint;

// Add one column at the right edge. `levels` holds `rows` values in 0..1,
// top row (highest frequency) first. Call flush once per frame afterwards.
- (void)appendColumn:(const float *)levels rows:(NSInteger)rows;

// Put the columns appended since the last flush on screen.
- (void)flush;

// Drop everything drawn so far.
- (void)clear;

@end

NS_ASSUME_NONNULL_END
