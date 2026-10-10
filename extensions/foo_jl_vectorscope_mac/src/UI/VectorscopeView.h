//
//  VectorscopeView.h
//  foo_jl_vectorscope_mac
//
//  Goniometer view: grid and correlation bars drawn with Core Graphics, the
//  afterglow trace composited on top as a layer image.
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class VectorscopeView;

@protocol VectorscopeViewDelegate <NSObject>
- (void)vectorscopeViewRequestsContextMenu:(VectorscopeView *)view atPoint:(NSPoint)point;
@end

@interface VectorscopeView : NSView

@property (nonatomic, weak, nullable) id<VectorscopeViewDelegate> delegate;

// Re-read display settings (colors, trace style, layout) from config.
- (void)reloadSettings;

// Advance the afterglow by `dt` seconds and add `count` goniometer points
// (interleaved x/y, -1..1, y up; may be 0 with a NULL pointer).
// Returns NO once the trace has fully faded and nothing is left to animate.
- (BOOL)advanceTrace:(nullable const float *)xy
               count:(NSInteger)count
          sampleRate:(double)sampleRate
           deltaTime:(double)dt;

// Latest correlation readings (-1..+1). `bands` holds low / mid / high and
// is only shown in the three-band layout. The bars ease towards the new
// values on the next advanceTrace:.
- (void)setCorrelation:(float)wide
                silent:(BOOL)wideSilent
                 bands:(const float *)bands
           bandsSilent:(const BOOL *)bandsSilent;

// Drop the trace and reset the bars (view went off-screen).
- (void)clearTrace;

@end

NS_ASSUME_NONNULL_END
