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
struct WaveformDetail;
namespace waveseek { struct PhraseGrid; }
#else
typedef struct WaveformData WaveformData;
typedef struct WaveformDetail WaveformDetail;
#endif

@class WaveformSeekbarView;

// Delegate protocol for view events
@protocol WaveformSeekbarViewDelegate <NSObject>
@optional
- (void)waveformSeekbarViewRequestsContextMenu:(WaveformSeekbarView *)view atPoint:(NSPoint)point;
- (void)waveformSeekbarView:(WaveformSeekbarView *)view requestsSeekToTime:(double)time;
// The playback position in seconds, read now (beat jumps and loops start from it)
- (double)waveformSeekbarViewPlaybackTime:(WaveformSeekbarView *)view;
@end

// The values are waveform_config::CursorEffect's
typedef NS_ENUM(NSInteger, WaveformCursorEffect) {
    WaveformCursorEffectNone = 0,           // Sharp transition
    WaveformCursorEffectGradient = 1,       // Fade gradient at edge
    WaveformCursorEffectGlow = 2,           // Bloom from the cursor line, pulsing
    WaveformCursorEffectScanline = 3,       // Multiple thin vertical lines
    WaveformCursorEffectPulse = 4,          // Breathing played area
    // 5 was Trail, retired: a stored 5 loads as Gradient
    WaveformCursorEffectShimmer = 6,        // Oscillating brightness bands
    WaveformCursorEffectParticles = 7,      // Sparks off the waveform (experimental)
    WaveformCursorEffectFirewall = 8,       // Flames standing on the cursor (experimental)
    WaveformCursorEffectEarthcrusher = 9    // Jagged cursor, scorched cracks behind it (experimental)
};

@interface WaveformSeekbarView : NSView

// Delegate for context menu events
@property (nonatomic, weak, nullable) id<WaveformSeekbarViewDelegate> delegate;

// Display properties
@property (nonatomic, assign) BOOL shadePlayedPortion;
@property (nonatomic, assign) CGFloat playedDimming;     // 0.0 to 1.0 (dimming opacity for played portion)
@property (nonatomic, assign) WaveformCursorEffect cursorEffect;
@property (nonatomic, assign) BOOL bpmSync;              // Sync cursor animations to BPM
@property (nonatomic, assign) double trackBpm;           // Current track's BPM (0 if unknown)
@property (nonatomic, assign) BOOL showCursorTime;       // elapsed time chip beside the cursor
@property (nonatomic, assign) BOOL glassBackground;      // Skip background fill so blur behind shows through

// Playback state
@property (nonatomic, assign) double playbackPosition;    // 0.0 to 1.0
@property (nonatomic, assign) double trackDuration;       // in seconds
@property (nonatomic, assign, getter=isPlaying) BOOL playing;
@property (nonatomic, assign, getter=isAnalyzing) BOOL analyzing;  // Shows "Analyzing..." message

// Zoom: 1 shows the whole track; wheel, trackpad scroll and pinch change it
@property (nonatomic, readonly) double zoomFactor;

// Colors (automatically switch based on appearance)
@property (nonatomic, strong) NSColor *waveformColor;
@property (nonatomic, strong) NSColor *backgroundColor;

// Waveform data (const pointer to C++ struct, not owned)
@property (nonatomic, nullable, assign) const WaveformData *waveformData;
// Its fine detail for deep zoom, when there is one (not owned); ignored
// unless it matches waveformData
@property (nonatomic, nullable, assign) const WaveformDetail *waveformDetail;
// The track's beat grid from BPM Analyzer, for phrase markers (not owned)
@property (nonatomic, nullable, assign) const waveseek::PhraseGrid *phraseGrid;

// A beat loop, if one is on: called with the playback position at every
// position check while playing; seeks back to the loop's start on time
- (void)followLoopAt:(double)seconds;
// The track time to show for foobar2000's playback position: while the
// loop DSP holds the playback, where its passes are, else `seconds`
- (double)displayedTimeFor:(double)seconds;
// The position checks (followLoopAt:) stopped: no decode-ahead or short
// steps are asked of the loop DSP until they come again
- (void)positionChecksStopped;

// Actions
- (void)clearWaveform;
- (void)refreshDisplay;
- (void)reloadSettings;

@end

NS_ASSUME_NONNULL_END
