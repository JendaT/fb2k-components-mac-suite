//
//  PlaybackControlsView.h
//  foo_jl_playback_controls_ext
//
//  Main container view with transport buttons, volume, and track info
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class PlaybackControlsView;

@protocol PlaybackControlsViewDelegate <NSObject>
@optional
- (void)controlsViewDidTapPlayPause:(PlaybackControlsView *)view;
- (void)controlsViewDidTapStop:(PlaybackControlsView *)view;
- (void)controlsViewDidTapPrevious:(PlaybackControlsView *)view;
- (void)controlsViewDidTapNext:(PlaybackControlsView *)view;
- (void)controlsView:(PlaybackControlsView *)view didChangeVolume:(float)volume;
- (void)controlsViewDidTapTrackInfo:(PlaybackControlsView *)view;
- (void)controlsViewDidRequestEditMode:(PlaybackControlsView *)view;
- (void)controlsViewDidChangeButtonOrder:(PlaybackControlsView *)view;
- (void)controlsViewDidRequestContextMenu:(PlaybackControlsView *)view atPoint:(NSPoint)point;
@end

// Button type identifiers
typedef NS_ENUM(NSInteger, PlaybackButtonType) {
    PlaybackButtonTypePrevious = 0,
    PlaybackButtonTypeStop = 1,
    PlaybackButtonTypePlayPause = 2,
    PlaybackButtonTypeNext = 3,
    PlaybackButtonTypeVolume = 4,
    PlaybackButtonTypeTrackInfo = 5
};

@interface PlaybackControlsView : NSView <NSDraggingSource, NSDraggingDestination>

@property (nonatomic, weak, nullable) id<PlaybackControlsViewDelegate> delegate;
@property (nonatomic, assign, readonly) BOOL isCompactMode;
@property (nonatomic, assign, readonly) BOOL isEditingMode;

// Initialize with display mode
- (instancetype)initWithCompactMode:(BOOL)compact;

// Update display state
- (void)updatePlayPauseState:(BOOL)isPlaying isPaused:(BOOL)isPaused;
- (void)updateVolume:(float)volumeDB;
- (void)updateTrackInfoWithTopRow:(NSString *)topRow bottomRow:(NSString *)bottomRow;

// Button ordering
- (NSArray<NSNumber *> *)buttonOrder;
- (void)setButtonOrder:(NSArray<NSNumber *> *)order;

// Editing mode
- (void)enterEditingMode;
- (void)exitEditingMode;

@end

NS_ASSUME_NONNULL_END
