//
//  VolumeSliderView.h
//  foo_jl_playback_controls_ext
//
//  Volume control slider with dB display
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class VolumeSliderView;

typedef NS_ENUM(NSInteger, VolumeSliderOrientation) {
    VolumeSliderOrientationHorizontal = 0,
    VolumeSliderOrientationVertical = 1
};

@protocol VolumeSliderViewDelegate <NSObject>
@optional
- (void)volumeSliderView:(VolumeSliderView *)view didChangeVolume:(float)volumeDB;
@end

@interface VolumeSliderView : NSView

@property (nonatomic, weak, nullable) id<VolumeSliderViewDelegate> delegate;
@property (nonatomic, assign) VolumeSliderOrientation orientation;

// Volume in dB (0 = max, -100 = mute)
@property (nonatomic, assign, readonly) float volumeDB;

// Set volume (updates slider position)
- (void)setVolumeDB:(float)volumeDB;

// Initialize with orientation
- (instancetype)initWithOrientation:(VolumeSliderOrientation)orientation;

@end

NS_ASSUME_NONNULL_END
