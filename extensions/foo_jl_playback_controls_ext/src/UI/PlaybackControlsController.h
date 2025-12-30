//
//  PlaybackControlsController.h
//  foo_jl_playback_controls_ext
//
//  Main controller for playback controls UI element
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class PlaybackControlsView;

// Notification posted when playback state changes
extern NSNotificationName const PlaybackControlsStateDidChangeNotification;

@interface PlaybackControlsController : NSViewController

// Initialize with optional layout parameters
- (instancetype)initWithParameters:(nullable NSDictionary<NSString*, NSString*>*)params;

// Instance identifier for per-instance configuration
@property (nonatomic, copy, readonly, nullable) NSString *instanceId;

// Playback state (read-only, updated via callbacks)
@property (nonatomic, assign, readonly) BOOL isPlaying;
@property (nonatomic, assign, readonly) BOOL isPaused;
@property (nonatomic, assign, readonly) float currentVolume;
@property (nonatomic, assign, readonly) double playbackTime;
@property (nonatomic, assign, readonly) double trackLength;

// Display text (formatted via titleformat)
@property (nonatomic, copy, readonly) NSString *topRowText;
@property (nonatomic, copy, readonly) NSString *bottomRowText;

// Actions
- (void)playOrPause;
- (void)stop;
- (void)previous;
- (void)next;
- (void)setVolume:(float)volume;
- (void)navigateToPlayingTrack;

// Enter/exit editing mode
- (void)enterEditingMode;
- (void)exitEditingMode;
@property (nonatomic, assign, readonly) BOOL isEditingMode;

// Update display (called from playback callbacks)
- (void)updatePlaybackState;
- (void)updateTrackInfo;
- (void)updateVolume:(float)volume;

// Shared instance for callback access
+ (nullable instancetype)activeController;

@end

NS_ASSUME_NONNULL_END
