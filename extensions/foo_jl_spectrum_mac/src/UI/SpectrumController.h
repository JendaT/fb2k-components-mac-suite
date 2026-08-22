//
//  SpectrumController.h
//  foo_jl_spectrum_mac
//
//  NSViewController hosting the spectrum view; drives the display timer.
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "SpectrumView.h"

NS_ASSUME_NONNULL_BEGIN

@interface SpectrumController : NSViewController <SpectrumViewDelegate>

@property (nonatomic, readonly) SpectrumView *spectrumView;

@end

NS_ASSUME_NONNULL_END
