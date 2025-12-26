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

typedef NS_ENUM(NSInteger, WaveformDisplayMode) {
    WaveformDisplayModeStereo = 0,  // Separate L/R channels
    WaveformDisplayModeMono = 1     // Mixed mono waveform
};

typedef NS_ENUM(NSInteger, WaveformCursorEffect) {
    WaveformCursorEffectNone = 0,      // Sharp transition
    WaveformCursorEffectGradient = 1,  // Fade gradient at edge
    WaveformCursorEffectGlow = 2,      // Pulsing halo/bloom
    WaveformCursorEffectScanline = 3,  // Multiple thin vertical lines
    WaveformCursorEffectPulse = 4,     // Breathing cursor line
    WaveformCursorEffectTrail = 5,     // Motion blur trail
    WaveformCursorEffectShimmer = 6    // Oscillating brightness bands
};

typedef NS_ENUM(NSInteger, WaveformRenderStyle) {
    WaveformRenderStyleSolid = 0,      // Single color
    WaveformRenderStyleHeatMap = 1,    // Amplitude to color gradient
    WaveformRenderStyleRainbow = 2     // Position-based rainbow
};

@interface WaveformSeekbarView : NSView

// Display properties
@property (nonatomic, assign) WaveformDisplayMode displayMode;
@property (nonatomic, assign) BOOL shadePlayedPortion;
@property (nonatomic, assign) CGFloat playedDimming;  // 0.0 to 1.0 (dimming opacity for played portion)
@property (nonatomic, assign) WaveformCursorEffect cursorEffect;
@property (nonatomic, assign) WaveformRenderStyle waveformStyle;
@property (nonatomic, assign) int gradientBands;  // 2-32, only applies to Solid style
@property (nonatomic, assign) BOOL bpmSync;       // Sync cursor animations to BPM
@property (nonatomic, assign) double trackBpm;    // Current track's BPM (0 if unknown)

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
