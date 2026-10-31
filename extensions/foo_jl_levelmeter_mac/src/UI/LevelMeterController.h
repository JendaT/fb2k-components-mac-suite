//
//  LevelMeterController.h
//  foo_jl_levelmeter_mac
//
//  NSViewController hosting the meter view; drives the display timer and
//  feeds the engine from the visualisation stream.
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "LevelMeterView.h"

NS_ASSUME_NONNULL_BEGIN

@interface LevelMeterController : NSViewController <LevelMeterViewDelegate>

@property (nonatomic, readonly) LevelMeterView *meterView;

@end

NS_ASSUME_NONNULL_END
