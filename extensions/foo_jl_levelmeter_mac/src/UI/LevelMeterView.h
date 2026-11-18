//
//  LevelMeterView.h
//  foo_jl_levelmeter_mac
//
//  Flipped view that draws the latest snapshot through MeterRenderer and
//  reports clicks (reset) and context-menu requests to its delegate.
//

#pragma once

#import <Cocoa/Cocoa.h>
#include "../Core/DisplaySettings.h"
#include "../Core/MeterEngine.h"

NS_ASSUME_NONNULL_BEGIN

@class LevelMeterView;

@protocol LevelMeterViewDelegate <NSObject>
- (void)levelMeterViewRequestsContextMenu:(LevelMeterView *)view atPoint:(NSPoint)point;
- (void)levelMeterViewResetPeaks:(LevelMeterView *)view;
- (void)levelMeterViewResetLoudness:(LevelMeterView *)view;
@end

@interface LevelMeterView : NSView

@property (nonatomic, weak, nullable) id<LevelMeterViewDelegate> delegate;

// Re-read display settings from config (colors follow the appearance).
- (void)reloadSettings;

// Show a new set of readings.
- (void)showSnapshot:(const meter::Snapshot &)snapshot;

@end

NS_ASSUME_NONNULL_END
