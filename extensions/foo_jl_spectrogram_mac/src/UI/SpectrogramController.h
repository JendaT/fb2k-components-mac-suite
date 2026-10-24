//
//  SpectrogramController.h
//  foo_jl_spectrogram_mac
//
//  NSViewController hosting the spectrogram view; drives the display timer
//  and turns elapsed stream time into new columns.
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "SpectrogramView.h"

NS_ASSUME_NONNULL_BEGIN

@interface SpectrogramController : NSViewController <SpectrogramViewDelegate>

@property (nonatomic, readonly) SpectrogramView *spectrogramView;

@end

NS_ASSUME_NONNULL_END
