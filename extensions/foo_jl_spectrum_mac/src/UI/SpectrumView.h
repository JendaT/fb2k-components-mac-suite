//
//  SpectrumView.h
//  foo_jl_spectrum_mac
//
//  Core Graphics view that renders frequency bars with falling peak caps.
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class SpectrumView;

@protocol SpectrumViewDelegate <NSObject>
- (void)spectrumViewRequestsContextMenu:(SpectrumView *)view atPoint:(NSPoint)point;
@end

@interface SpectrumView : NSView

@property (nonatomic, weak, nullable) id<SpectrumViewDelegate> delegate;

// Whether audio is currently being displayed (affects the idle placeholder).
@property (nonatomic) BOOL playing;

// Re-read display settings (colors, style, gap, peak hold) from config.
- (void)reloadSettings;

// Provide the latest bar magnitudes and peak positions (each 0..1) and redraw.
- (void)setBarsData:(const float *)bars peaks:(const float *)peaks count:(NSInteger)count;

@end

NS_ASSUME_NONNULL_END
