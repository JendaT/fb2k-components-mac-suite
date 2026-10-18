//
//  WaveformSeekbarView.h
//  foo_wave_seekbar_mac
//
//  Custom NSView for rendering the waveform seekbar
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declaration for C++ struct
#ifdef __cplusplus
struct WaveformData;
#else
typedef struct WaveformData WaveformData;
#endif

@class WaveformSeekbarView;

// Delegate protocol for view events
@protocol WaveformSeekbarViewDelegate <NSObject>
@optional
- (void)waveformSeekbarViewRequestsContextMenu:(WaveformSeekbarView *)view atPoint:(NSPoint)point;
- (void)waveformSeekbarView:(WaveformSeekbarView *)view requestsSeekToTime:(double)time;
@end

@interface WaveformSeekbarView : NSView

// Delegate for context menu events
@property (nonatomic, weak, nullable) id<WaveformSeekbarViewDelegate> delegate;

// Display properties
@property (nonatomic, assign) CGFloat playedOpacity;     // 0.2 to 1.0; the part still to play is opaque
@property (nonatomic, assign) BOOL showCursorTime;       // elapsed time chip beside the cursor
@property (nonatomic, assign) BOOL glassBackground;      // Skip background fill so blur behind shows through

// Playback state
@property (nonatomic, assign) double playbackPosition;    // 0.0 to 1.0
@property (nonatomic, assign) double trackDuration;       // in seconds
@property (nonatomic, assign, getter=isPlaying) BOOL playing;
@property (nonatomic, assign, getter=isAnalyzing) BOOL analyzing;  // Shows "Analyzing..." message

// Colors (automatically switch based on appearance)
@property (nonatomic, strong) NSColor *waveformColor;
@property (nonatomic, strong) NSColor *backgroundColor;

// Waveform data (const pointer to C++ struct, not owned)
@property (nonatomic, nullable, assign) const WaveformData *waveformData;

// Actions
- (void)clearWaveform;
- (void)refreshDisplay;
- (void)reloadSettings;

@end

NS_ASSUME_NONNULL_END
