//
//  WaveformSeekbarController.h
//  foo_wave_seekbar_mac
//
//  View controller for the waveform seekbar UI element
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "WaveformSeekbarView.h"
#include "../fb2k_sdk.h"

NS_ASSUME_NONNULL_BEGIN

struct WaveformData;

@interface WaveformSeekbarController : NSViewController <WaveformSeekbarViewDelegate>

@property (nonatomic, readonly) WaveformSeekbarView *waveformView;

// Playback event handlers (called from PlaybackCallback)
- (void)handleNewTrack:(metadb_handle_ptr)track duration:(double)duration bpm:(double)bpm;
- (void)handlePlaybackStop;
- (void)handleSeekToTime:(double)time;
- (void)handlePlaybackTime:(double)time;
- (void)handlePlaybackPause:(BOOL)paused;

// Waveform data update
- (void)updateWaveformData:(const WaveformData *)waveform;

@end

NS_ASSUME_NONNULL_END
