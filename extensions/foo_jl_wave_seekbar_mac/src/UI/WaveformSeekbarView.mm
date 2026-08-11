//
//  WaveformSeekbarView.mm
//  foo_wave_seekbar_mac
//
//  Custom NSView for rendering the waveform seekbar
//

#import "WaveformSeekbarView.h"
#include "../fb2k_sdk.h"
#include "../Core/WaveformData.h"
#include "../Core/WaveformConfig.h"
#include "../Core/ConfigHelper.h"
#include "../Core/WaveformColorMap.h"
#include "../Core/WaveformGeometry.h"
#include <cmath>

@interface WaveformSeekbarView () {
    NSTrackingArea *_trackingArea;
    const WaveformData *_cachedWaveform;
    CGColorSpaceRef _deviceRGBColorSpace;       // Cached for reuse across frames
    NSDictionary *_placeholderAttributes;        // Cached placeholder text attributes
}

@end

@implementation WaveformSeekbarView

#pragma mark - Initialization

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    // Cache color space for reuse across draw calls
    _deviceRGBColorSpace = CGColorSpaceCreateDeviceRGB();

    // Cache placeholder text attributes
    _placeholderAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
    };

    // Default display settings from config
    [self reloadSettings];

    // Default playback state
    _playbackPosition = 0.0;
    _trackDuration = 0.0;
    _playing = NO;

    // Default colors (will be updated based on appearance)
    [self updateColorsForAppearance];

    // Enable layer backing for better performance
    self.wantsLayer = YES;
    self.layer.cornerRadius = 6.0;
    self.layer.masksToBounds = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;

    // Listen for settings changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSettingsChanged:)
                                                 name:@"WaveformSeekbarSettingsChanged"
                                               object:nil];

    // Accessibility
    [self setAccessibilityRole:NSAccessibilitySliderRole];
    [self setAccessibilityLabel:@"Waveform Seekbar"];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_deviceRGBColorSpace) {
        CGColorSpaceRelease(_deviceRGBColorSpace);
    }
}

- (void)handleSettingsChanged:(NSNotification *)notification {
    [self reloadSettings];
}

- (void)reloadSettings {
    using namespace waveform_config;
    _displayMode = static_cast<WaveformDisplayMode>(getConfigInt(kKeyDisplayMode, kDefaultDisplayMode));
    _shadePlayedPortion = getConfigBool(kKeyShadePlayedPortion, kDefaultShadePlayedPortion);
    _playedDimming = getConfigInt(kKeyPlayedDimming, kDefaultPlayedDimming) / 100.0;  // Convert 0-100 to 0.0-1.0
    _cursorEffect = static_cast<WaveformCursorEffect>(getConfigInt(kKeyCursorEffect, kDefaultCursorEffect));
    _waveformStyle = static_cast<WaveformRenderStyle>(getConfigInt(kKeyWaveformStyle, kDefaultWaveformStyle));
    _gradientBands = static_cast<int>(getConfigInt(kKeyGradientBands, kDefaultGradientBands));
    _bpmSync = getConfigBool(kKeyBpmSync, kDefaultBpmSync);
    _glassBackground = getConfigBool(kKeyGlassBackground, kDefaultGlassBackground);
    [self updateColorsForAppearance];
    [self setNeedsDisplay:YES];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }

    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
        options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInKeyWindow)
        owner:self
        userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

#pragma mark - Appearance

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateColorsForAppearance];
    [self setNeedsDisplay:YES];
}

- (void)updateColorsForAppearance {
    using namespace waveform_config;

    NSAppearanceName appearanceName = [self.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];

    BOOL isDarkMode = [appearanceName isEqualToString:NSAppearanceNameDarkAqua];

    // Get colors from config
    uint32_t waveARGB, bgARGB;

    if (isDarkMode) {
        waveARGB = static_cast<uint32_t>(getConfigInt(kKeyWaveColorDark, kDefaultWaveColorDark));
        bgARGB = static_cast<uint32_t>(getConfigInt(kKeyBgColorDark, kDefaultBgColorDark));
    } else {
        waveARGB = static_cast<uint32_t>(getConfigInt(kKeyWaveColorLight, kDefaultWaveColorLight));
        bgARGB = static_cast<uint32_t>(getConfigInt(kKeyBgColorLight, kDefaultBgColorLight));
    }

    // Convert ARGB to NSColor
    waveseek::Rgba wave = waveseek::rgbaFromArgb(waveARGB);
    waveseek::Rgba background = waveseek::rgbaFromArgb(bgARGB);

    _waveformColor = [NSColor colorWithRed:wave.r green:wave.g blue:wave.b alpha:wave.a];
    _backgroundColor = [NSColor colorWithRed:background.r green:background.g
                                        blue:background.b alpha:background.a];
}

#pragma mark - Drawing

- (BOOL)isOpaque {
    if (self.glassBackground) return NO;
    return self.backgroundColor.alphaComponent >= 1.0;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    if (!context) return;

    CGRect bounds = self.bounds;

    // Draw background - in glass mode skip an opaque color so the blur shows
    // through, but let a translucent color act as a tint over the blur
    CGFloat bgAlpha = self.backgroundColor.alphaComponent;
    if (!self.glassBackground || (bgAlpha > 0.0 && bgAlpha < 1.0)) {
        CGContextSetFillColorWithColor(context, self.backgroundColor.CGColor);
        CGContextFillRect(context, bounds);
    }

    // Draw waveform or placeholder
    if (self.waveformData && self.waveformData->isValid()) {
        [self drawWaveformInContext:context bounds:bounds];
    } else {
        [self drawPlaceholderInContext:context bounds:bounds];
    }

    // Draw played portion overlay (works even without waveform)
    if (self.shadePlayedPortion && self.playbackPosition > 0.0) {
        [self drawPlayedOverlayInContext:context bounds:bounds];
    }

    // Draw position indicator (works even without waveform)
    [self drawPositionIndicatorInContext:context bounds:bounds];
}

- (void)drawPlaceholderInContext:(CGContextRef)context bounds:(CGRect)bounds {
    // Draw a placeholder message using cached attributes
    NSString *text = self.analyzing ? @"Analyzing..." : @"No waveform";
    NSSize textSize = [text sizeWithAttributes:_placeholderAttributes];

    NSPoint point = NSMakePoint(
        (bounds.size.width - textSize.width) / 2,
        (bounds.size.height - textSize.height) / 2
    );

    [text drawAtPoint:point withAttributes:_placeholderAttributes];
}

#pragma mark - Waveform Rendering

// Peak deflection drawn for one bucket of a single channel.
static double channelPeak(const WaveformData *waveform, uint32_t channel, size_t bucket) {
    return waveseek::peakAmplitude(waveform->min[channel][bucket], waveform->max[channel][bucket]);
}

// Peak deflection for the collapsed mono trace. The per-bucket colour styles
// fold with the stereo envelope while solid folds with the average; the two
// disagree on wide-stereo material, and WaveformGeometry.h spells out why
// both survive.
static double monoPeak(const WaveformData *waveform, uint32_t channels, size_t bucket, bool useAverage) {
    if (channels < 2) {
        return channelPeak(waveform, 0, bucket);
    }

    waveseek::MinMax folded = useAverage
        ? waveseek::monoDownmixAverage(waveform->min[0][bucket], waveform->max[0][bucket],
                                       waveform->min[1][bucket], waveform->max[1][bucket])
        : waveseek::monoDownmixEnvelope(waveform->min[0][bucket], waveform->max[0][bucket],
                                        waveform->min[1][bucket], waveform->max[1][bucket]);
    return waveseek::peakAmplitude(folded.min, folded.max);
}

- (void)drawWaveformInContext:(CGContextRef)context bounds:(CGRect)bounds {
    const WaveformData* waveform = self.waveformData;
    if (!waveform || !waveform->isValid()) return;

    bool isStereo = (waveform->channelCount == 2 && self.displayMode == WaveformDisplayModeStereo);
    CGFloat viewWidth = bounds.size.width;
    CGFloat viewHeight = bounds.size.height;

    waveseek::ChannelLayout upper = isStereo ? waveseek::stereoLeftLayout(viewHeight)
                                             : waveseek::monoLayout(viewHeight);

    // Heat map and rainbow colour each bucket individually; solid uses the
    // configured colour, optionally split into fading bands.
    if (self.waveformStyle != WaveformRenderStyleSolid) {
        if (isStereo) {
            waveseek::ChannelLayout lower = waveseek::stereoRightLayout(viewHeight);
            [self drawColoredTraceInContext:context layout:upper viewWidth:viewWidth channel:0];
            [self drawColoredTraceInContext:context layout:lower viewWidth:viewWidth channel:1];
        } else {
            [self drawColoredTraceInContext:context layout:upper viewWidth:viewWidth channel:-1];
        }
        return;
    }

    NSColor *baseColor = [self.waveformColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!baseColor) baseColor = self.waveformColor;
    int bands = waveseek::clampGradientBands(self.gradientBands);

    if (isStereo) {
        waveseek::ChannelLayout lower = waveseek::stereoRightLayout(viewHeight);
        [self drawSolidTraceInContext:context layout:upper viewWidth:viewWidth
                              channel:0 bands:bands color:baseColor];
        [self drawSolidTraceInContext:context layout:lower viewWidth:viewWidth
                              channel:1 bands:bands color:baseColor];
    } else {
        [self drawSolidTraceInContext:context layout:upper viewWidth:viewWidth
                              channel:-1 bands:bands color:baseColor];
    }
}

// Peak per bucket for one trace, computed once up front: the banded path
// reads each bucket once per band, and recomputing the fold every time was
// the bulk of its work. channel >= 0 selects that channel, -1 the mono
// downmix.
- (void)fillPeaks:(float *)peaks channel:(int)channel useAverageDownmix:(BOOL)useAverage {
    const WaveformData *waveform = self.waveformData;
    uint32_t channels = waveform->channelCount;

    for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
        double peak = (channel >= 0)
            ? channelPeak(waveform, static_cast<uint32_t>(channel), i)
            : monoPeak(waveform, channels, i, useAverage);
        peaks[i] = static_cast<float>(peak);
    }
}

// One stroke per bucket, since every bucket carries its own colour.
- (void)drawColoredTraceInContext:(CGContextRef)context
                           layout:(waveseek::ChannelLayout)layout
                        viewWidth:(CGFloat)viewWidth
                          channel:(int)channel {
    float peaks[WaveformData::BUCKET_COUNT];
    [self fillPeaks:peaks channel:channel useAverageDownmix:NO];

    BOOL isHeatMap = (self.waveformStyle == WaveformRenderStyleHeatMap);
    CGContextSetLineWidth(context, 1.0);

    for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
        CGFloat x = waveseek::bucketX(i, WaveformData::BUCKET_COUNT, viewWidth);
        CGFloat peak = peaks[i];

        waveseek::Rgb color = isHeatMap
            ? waveseek::heatMapColor(peak)
            : waveseek::rainbowColor(waveseek::bucketPosition(i, WaveformData::BUCKET_COUNT));

        CGContextSetRGBStrokeColor(context, color.r, color.g, color.b, 1.0);
        CGContextBeginPath(context);
        CGContextMoveToPoint(context, x, layout.centerY - peak * layout.amplitude);
        CGContextAddLineToPoint(context, x, layout.centerY + peak * layout.amplitude);
        CGContextStrokePath(context);
    }
}

// A single colour: either a flat trace, or stacked translucent bands that
// fade as they move away from the baseline.
- (void)drawSolidTraceInContext:(CGContextRef)context
                         layout:(waveseek::ChannelLayout)layout
                      viewWidth:(CGFloat)viewWidth
                        channel:(int)channel
                          bands:(int)bands
                          color:(NSColor *)color {
    float peaks[WaveformData::BUCKET_COUNT];
    [self fillPeaks:peaks channel:channel useAverageDownmix:YES];

    CGFloat r = color.redComponent;
    CGFloat g = color.greenComponent;
    CGFloat b = color.blueComponent;
    CGContextSetLineWidth(context, 1.0);

    if (bands <= 0) {
        CGContextSetRGBStrokeColor(context, r, g, b, 1.0);
        CGContextBeginPath(context);
        for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
            CGFloat x = waveseek::bucketX(i, WaveformData::BUCKET_COUNT, viewWidth);
            CGFloat peak = peaks[i];
            CGContextMoveToPoint(context, x, layout.centerY - peak * layout.amplitude);
            CGContextAddLineToPoint(context, x, layout.centerY + peak * layout.amplitude);
        }
        CGContextStrokePath(context);
        return;
    }

    for (int band = 0; band < bands; band++) {
        waveseek::BandRange range = waveseek::bandRange(band, bands);
        CGContextSetRGBStrokeColor(context, r, g, b, waveseek::bandAlpha(band, bands));
        CGContextBeginPath(context);

        for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
            CGFloat peak = peaks[i];
            if (peak <= range.start) continue;  // this bucket never reaches the band

            CGFloat x = waveseek::bucketX(i, WaveformData::BUCKET_COUNT, viewWidth);
            CGFloat inner = range.start * layout.amplitude;
            CGFloat outer = std::min<CGFloat>(peak, range.end) * layout.amplitude;

            CGContextMoveToPoint(context, x, layout.centerY + inner);
            CGContextAddLineToPoint(context, x, layout.centerY + outer);
            CGContextMoveToPoint(context, x, layout.centerY - inner);
            CGContextAddLineToPoint(context, x, layout.centerY - outer);
        }
        CGContextStrokePath(context);
    }
}

// Get animation frequency: uses BPM if sync enabled, otherwise returns default
- (CGFloat)animationFrequencyWithDefault:(CGFloat)defaultHz {
    return waveseek::animationFrequency(self.bpmSync, self.trackBpm, defaultHz);
}

- (void)drawPlayedOverlayInContext:(CGContextRef)context bounds:(CGRect)bounds {
    if (self.playedDimming <= 0.0) return;  // No dimming

    CGFloat playedWidth = bounds.size.width * self.playbackPosition;
    if (playedWidth <= 0) return;

    // Over glass, dim with a neutral appearance-matched shade so the blur stays
    // visible instead of painting the configured background color
    NSColor *dimBase = self.backgroundColor;
    if (self.glassBackground) {
        NSAppearanceName appearanceName = [self.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        BOOL isDark = [appearanceName isEqualToString:NSAppearanceNameDarkAqua];
        dimBase = isDark ? [NSColor blackColor] : [NSColor whiteColor];
    }

    NSColor *bgDeviceColor = [dimBase colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (!bgDeviceColor) return;

    CGFloat dimOpacity = self.playedDimming;

    // Draw solid dimming for played portion based on cursor effect
    switch (self.cursorEffect) {
        case WaveformCursorEffectNone:
            [self drawNoneEffectInContext:context bounds:bounds playedWidth:playedWidth
                                 bgColor:bgDeviceColor dimOpacity:dimOpacity];
            break;
        case WaveformCursorEffectGradient:
            [self drawGradientEffectInContext:context bounds:bounds playedWidth:playedWidth
                                     bgColor:bgDeviceColor dimOpacity:dimOpacity];
            break;
        case WaveformCursorEffectGlow:
            [self drawGlowEffectInContext:context bounds:bounds playedWidth:playedWidth
                                 bgColor:bgDeviceColor dimOpacity:dimOpacity];
            break;
        case WaveformCursorEffectScanline:
            [self drawScanlineEffectInContext:context bounds:bounds playedWidth:playedWidth
                                     bgColor:bgDeviceColor dimOpacity:dimOpacity];
            break;
        case WaveformCursorEffectPulse:
            [self drawPulseEffectInContext:context bounds:bounds playedWidth:playedWidth
                                  bgColor:bgDeviceColor dimOpacity:dimOpacity];
            break;
        case WaveformCursorEffectTrail:
            [self drawTrailEffectInContext:context bounds:bounds playedWidth:playedWidth
                                  bgColor:bgDeviceColor dimOpacity:dimOpacity];
            break;
        case WaveformCursorEffectShimmer:
            [self drawShimmerEffectInContext:context bounds:bounds playedWidth:playedWidth
                                    bgColor:bgDeviceColor dimOpacity:dimOpacity];
            break;
    }
}

#pragma mark - Cursor Effects

// Effect 0: None - Sharp transition, uniform dimming
- (void)drawNoneEffectInContext:(CGContextRef)context bounds:(CGRect)bounds
                    playedWidth:(CGFloat)playedWidth bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity {
    NSColor *dimColor = [NSColor colorWithRed:bgColor.redComponent
                                        green:bgColor.greenComponent
                                         blue:bgColor.blueComponent
                                        alpha:dimOpacity];
    CGContextSetFillColorWithColor(context, dimColor.CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, playedWidth, bounds.size.height));
}

// Effect 1: Gradient - Fade at the edge
- (void)drawGradientEffectInContext:(CGContextRef)context bounds:(CGRect)bounds
                        playedWidth:(CGFloat)playedWidth bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity {
    CGFloat fadeWidth = waveseek::cursorFadeWidth(bounds.size.width);

    CGColorSpaceRef colorSpace = _deviceRGBColorSpace;
    if (!colorSpace) return;

    CGFloat components[8] = {
        bgColor.redComponent, bgColor.greenComponent, bgColor.blueComponent, dimOpacity,
        bgColor.redComponent, bgColor.greenComponent, bgColor.blueComponent, 0.0
    };

    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, NULL, 2);
    if (!gradient) return;

    // Solid portion
    if (playedWidth > fadeWidth) {
        NSColor *dimColor = [NSColor colorWithRed:bgColor.redComponent green:bgColor.greenComponent
                                             blue:bgColor.blueComponent alpha:dimOpacity];
        CGContextSetFillColorWithColor(context, dimColor.CGColor);
        CGContextFillRect(context, CGRectMake(0, 0, playedWidth - fadeWidth, bounds.size.height));
    }

    // Gradient fade
    CGContextSaveGState(context);
    CGContextClipToRect(context, CGRectMake(MAX(0, playedWidth - fadeWidth), 0, fadeWidth, bounds.size.height));
    CGContextDrawLinearGradient(context, gradient,
        CGPointMake(playedWidth - fadeWidth, 0), CGPointMake(playedWidth, 0), 0);
    CGContextRestoreGState(context);

    CGGradientRelease(gradient);
}

// Effect 2: Glow - Pulsing halo at cursor position
- (void)drawGlowEffectInContext:(CGContextRef)context bounds:(CGRect)bounds
                    playedWidth:(CGFloat)playedWidth bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity {
    // Draw solid dimming first
    NSColor *dimColor = [NSColor colorWithRed:bgColor.redComponent green:bgColor.greenComponent
                                         blue:bgColor.blueComponent alpha:dimOpacity];
    CGContextSetFillColorWithColor(context, dimColor.CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, playedWidth, bounds.size.height));

    // Pulsing glow at cursor
    CGFloat time = CFAbsoluteTimeGetCurrent();
    CGFloat pulse = waveseek::oscillator(time, [self animationFrequencyWithDefault:1.0]);
    CGFloat glowWidth = 20.0 + pulse * 10.0;  // 20-30px glow

    CGColorSpaceRef colorSpace = _deviceRGBColorSpace;
    if (!colorSpace) return;

    // Glow uses waveform color
    NSColor *waveDeviceColor = [self.waveformColor colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (!waveDeviceColor) return;

    CGFloat glowAlpha = 0.3 + pulse * 0.4;  // 0.3-0.7 alpha
    CGFloat components[8] = {
        waveDeviceColor.redComponent, waveDeviceColor.greenComponent, waveDeviceColor.blueComponent, glowAlpha,
        waveDeviceColor.redComponent, waveDeviceColor.greenComponent, waveDeviceColor.blueComponent, 0.0
    };

    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, NULL, 2);
    if (!gradient) return;

    // Draw glow on both sides of cursor
    CGContextSaveGState(context);
    CGContextClipToRect(context, CGRectMake(playedWidth - glowWidth, 0, glowWidth * 2, bounds.size.height));
    CGContextDrawLinearGradient(context, gradient,
        CGPointMake(playedWidth - glowWidth, 0), CGPointMake(playedWidth, 0), 0);
    CGContextDrawLinearGradient(context, gradient,
        CGPointMake(playedWidth + glowWidth, 0), CGPointMake(playedWidth, 0), 0);
    CGContextRestoreGState(context);

    CGGradientRelease(gradient);
}

// Effect 3: Scanline - Animated lines traveling near cursor
- (void)drawScanlineEffectInContext:(CGContextRef)context bounds:(CGRect)bounds
                        playedWidth:(CGFloat)playedWidth bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity {
    // Draw solid dimming first
    NSColor *dimColor = [NSColor colorWithRed:bgColor.redComponent green:bgColor.greenComponent
                                         blue:bgColor.blueComponent alpha:dimOpacity];
    CGContextSetFillColorWithColor(context, dimColor.CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, playedWidth, bounds.size.height));

    NSColor *waveDeviceColor = [self.waveformColor colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (!waveDeviceColor) return;

    // Animated scanlines traveling near cursor
    CGFloat time = CFAbsoluteTimeGetCurrent();
    CGFloat scanRange = 30.0;  // Lines travel within 30px of cursor
    CGFloat baseFreq = [self animationFrequencyWithDefault:1.0];  // Base frequency

    // 4 lines with different speeds and phases (multipliers of base frequency)
    CGFloat speeds[] = {baseFreq * 2.5, -baseFreq * 1.8, baseFreq * 3.2, -baseFreq * 2.1};
    CGFloat phases[] = {0.0, 1.57, 3.14, 4.71};  // Different phase offsets
    CGFloat alphas[] = {0.3, 0.25, 0.35, 0.2};  // More subtle/transparent

    CGContextSetLineWidth(context, 1.5);

    for (int i = 0; i < 4; i++) {
        // Calculate position using sine wave for smooth back-and-forth motion
        CGFloat offset = sin(time * speeds[i] + phases[i]) * scanRange;
        CGFloat x = playedWidth + offset;

        if (x < 0 || x > bounds.size.width) continue;

        // Fade alpha based on distance from cursor
        CGFloat distanceFade = 1.0 - (fabs(offset) / scanRange) * 0.5;
        CGFloat alpha = alphas[i] * distanceFade;

        CGContextSetRGBStrokeColor(context,
            waveDeviceColor.redComponent, waveDeviceColor.greenComponent,
            waveDeviceColor.blueComponent, alpha);
        CGContextBeginPath(context);
        CGContextMoveToPoint(context, x, 0);
        CGContextAddLineToPoint(context, x, bounds.size.height);
        CGContextStrokePath(context);
    }
}

// Effect 4: Pulse - Entire played area breathes in opacity
- (void)drawPulseEffectInContext:(CGContextRef)context bounds:(CGRect)bounds
                     playedWidth:(CGFloat)playedWidth bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity {
    // Breathing opacity for the entire played area
    CGFloat time = CFAbsoluteTimeGetCurrent();
    CGFloat breath = waveseek::oscillator(time, [self animationFrequencyWithDefault:1.5]);

    // Modulate dimOpacity: ranges from dimOpacity*0.3 to dimOpacity*1.0
    CGFloat pulsingOpacity = dimOpacity * (0.3 + breath * 0.7);

    NSColor *dimColor = [NSColor colorWithRed:bgColor.redComponent green:bgColor.greenComponent
                                         blue:bgColor.blueComponent alpha:pulsingOpacity];
    CGContextSetFillColorWithColor(context, dimColor.CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, playedWidth, bounds.size.height));
}

// Effect 5: Trail - Motion blur trail behind cursor
- (void)drawTrailEffectInContext:(CGContextRef)context bounds:(CGRect)bounds
                     playedWidth:(CGFloat)playedWidth bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity {
    CGFloat trailLength = 40.0;  // Trail extends 40px behind cursor

    // Draw solid dimming for area before trail
    if (playedWidth > trailLength) {
        NSColor *dimColor = [NSColor colorWithRed:bgColor.redComponent green:bgColor.greenComponent
                                             blue:bgColor.blueComponent alpha:dimOpacity];
        CGContextSetFillColorWithColor(context, dimColor.CGColor);
        CGContextFillRect(context, CGRectMake(0, 0, playedWidth - trailLength, bounds.size.height));
    }

    // Draw gradient trail
    CGColorSpaceRef colorSpace = _deviceRGBColorSpace;
    if (!colorSpace) return;

    CGFloat components[8] = {
        bgColor.redComponent, bgColor.greenComponent, bgColor.blueComponent, dimOpacity,
        bgColor.redComponent, bgColor.greenComponent, bgColor.blueComponent, 0.0
    };

    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, NULL, 2);
    if (!gradient) return;

    CGFloat trailStart = MAX(0, playedWidth - trailLength);
    CGContextSaveGState(context);
    CGContextClipToRect(context, CGRectMake(trailStart, 0, trailLength, bounds.size.height));
    CGContextDrawLinearGradient(context, gradient,
        CGPointMake(trailStart, 0), CGPointMake(playedWidth, 0), 0);
    CGContextRestoreGState(context);

    CGGradientRelease(gradient);
}

// Effect 6: Shimmer - Oscillating brightness bands
- (void)drawShimmerEffectInContext:(CGContextRef)context bounds:(CGRect)bounds
                       playedWidth:(CGFloat)playedWidth bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity {
    // Draw base dimming
    NSColor *dimColor = [NSColor colorWithRed:bgColor.redComponent green:bgColor.greenComponent
                                         blue:bgColor.blueComponent alpha:dimOpacity * 0.7];
    CGContextSetFillColorWithColor(context, dimColor.CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, playedWidth, bounds.size.height));

    // Draw shimmering bands near cursor
    CGFloat time = CFAbsoluteTimeGetCurrent();
    CGFloat shimmerWidth = 30.0;
    CGFloat bandCount = 5;
    CGFloat baseFreq = [self animationFrequencyWithDefault:2.5];  // Default 2.5Hz

    NSColor *waveDeviceColor = [self.waveformColor colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (!waveDeviceColor) return;

    for (int i = 0; i < bandCount; i++) {
        CGFloat shimmer = waveseek::oscillator(time, baseFreq, i * 0.8);  // Different phase per band
        CGFloat bandAlpha = shimmer * 0.3;  // 0-0.3 alpha

        CGFloat bandX = playedWidth - shimmerWidth + (i * shimmerWidth / bandCount);
        CGFloat bandW = shimmerWidth / bandCount;

        if (bandX < 0) continue;

        CGContextSetRGBFillColor(context,
            waveDeviceColor.redComponent, waveDeviceColor.greenComponent,
            waveDeviceColor.blueComponent, bandAlpha);
        CGContextFillRect(context, CGRectMake(bandX, 0, bandW, bounds.size.height));
    }
}

- (void)drawPositionIndicatorInContext:(CGContextRef)context bounds:(CGRect)bounds {
    if (self.playbackPosition <= 0.0) return;

    CGFloat x = bounds.size.width * self.playbackPosition;

    CGContextSetStrokeColorWithColor(context, [NSColor whiteColor].CGColor);
    CGContextSetLineWidth(context, 1.0);

    CGContextBeginPath(context);
    CGContextMoveToPoint(context, x, 0);
    CGContextAddLineToPoint(context, x, bounds.size.height);
    CGContextStrokePath(context);
}

#pragma mark - Mouse Events

- (void)mouseDown:(NSEvent *)event {
    [self handleSeekWithEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self handleSeekWithEvent:event];
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    FB2K_console_formatter() << "[WaveSeek] rightMouseDown triggered at " << location.x << "," << location.y;

    if ([self.delegate respondsToSelector:@selector(waveformSeekbarViewRequestsContextMenu:atPoint:)]) {
        FB2K_console_formatter() << "[WaveSeek] Calling delegate";
        [self.delegate waveformSeekbarViewRequestsContextMenu:self atPoint:location];
    } else {
        FB2K_console_formatter() << "[WaveSeek] No delegate or delegate doesn't respond";
    }
}

- (void)handleSeekWithEvent:(NSEvent *)event {
    if (self.trackDuration <= 0.0) return;

    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    double normalizedPosition = waveseek::normalizedPositionForX(location.x, self.bounds.size.width);
    double seekTime = waveseek::seekTimeForPosition(normalizedPosition, self.trackDuration);

    // Seek via SDK - must be on main thread
    if ([NSThread isMainThread]) {
        [self performSeekToTime:seekTime];
    } else {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf performSeekToTime:seekTime];
        });
    }
}

- (void)performSeekToTime:(double)seekTime {
    if ([self.delegate respondsToSelector:@selector(waveformSeekbarView:requestsSeekToTime:)]) {
        [self.delegate waveformSeekbarView:self requestsSeekToTime:seekTime];
    }
}

#pragma mark - Public Methods

- (void)clearWaveform {
    self.waveformData = nil;
    self.playbackPosition = 0.0;
    self.trackDuration = 0.0;
    [self setNeedsDisplay:YES];
}

- (void)refreshDisplay {
    [self setNeedsDisplay:YES];
}

#pragma mark - Accessibility

- (NSString *)accessibilityValue {
    if (self.trackDuration <= 0) {
        return @"No track loaded";
    }

    double currentTime = self.playbackPosition * self.trackDuration;
    return [NSString stringWithFormat:@"%.0f of %.0f seconds", currentTime, self.trackDuration];
}

- (BOOL)accessibilityPerformIncrement {
    return [self nudgePlaybackBySeconds:5.0];
}

- (BOOL)accessibilityPerformDecrement {
    return [self nudgePlaybackBySeconds:-5.0];
}

- (BOOL)nudgePlaybackBySeconds:(double)seconds {
    if (self.trackDuration <= 0) return NO;

    double newPosition = waveseek::nudgedPosition(self.playbackPosition, self.trackDuration, seconds);
    [self performSeekToTime:waveseek::seekTimeForPosition(newPosition, self.trackDuration)];
    return YES;
}

@end
