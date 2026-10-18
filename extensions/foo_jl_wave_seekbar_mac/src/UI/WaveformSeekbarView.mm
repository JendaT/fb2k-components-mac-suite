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
#include <algorithm>
#include <cmath>
#include <vector>

@interface WaveformSeekbarView () {
    NSTrackingArea *_trackingArea;
    CGImageRef _waveformImage;                   // Rendered waveform, see drawWaveformInContext
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
    CGImageRelease(_waveformImage);
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
    _amplitudeScale = static_cast<WaveformAmplitudeScale>(getConfigInt(kKeyAmplitudeScale, kDefaultAmplitudeScale));
    _bpmSync = getConfigBool(kKeyBpmSync, kDefaultBpmSync);
    _glassBackground = getConfigBool(kKeyGlassBackground, kDefaultGlassBackground);
    [self updateColorsForAppearance];
    [self invalidateWaveformImage];
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
    [self invalidateWaveformImage];
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
    _waveformColor = [NSColor colorWithRed:((waveARGB >> 16) & 0xFF) / 255.0
                                     green:((waveARGB >> 8) & 0xFF) / 255.0
                                      blue:(waveARGB & 0xFF) / 255.0
                                     alpha:((waveARGB >> 24) & 0xFF) / 255.0];

    _backgroundColor = [NSColor colorWithRed:((bgARGB >> 16) & 0xFF) / 255.0
                                       green:((bgARGB >> 8) & 0xFF) / 255.0
                                        blue:(bgARGB & 0xFF) / 255.0
                                       alpha:((bgARGB >> 24) & 0xFF) / 255.0];
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

// Helper: Get color for heat map based on amplitude (0-1)
// Blue (cold/quiet) → Cyan → Green → Yellow → Red (hot/loud)
- (void)getHeatMapColorForAmplitude:(CGFloat)amplitude r:(CGFloat*)r g:(CGFloat*)g b:(CGFloat*)b {
    // Clamp to 0-1
    amplitude = MAX(0.0, MIN(1.0, amplitude));

    if (amplitude < 0.25) {
        // Blue to Cyan (0.0 - 0.25)
        CGFloat t = amplitude / 0.25;
        *r = 0.0;
        *g = t;
        *b = 1.0;
    } else if (amplitude < 0.5) {
        // Cyan to Green (0.25 - 0.5)
        CGFloat t = (amplitude - 0.25) / 0.25;
        *r = 0.0;
        *g = 1.0;
        *b = 1.0 - t;
    } else if (amplitude < 0.75) {
        // Green to Yellow (0.5 - 0.75)
        CGFloat t = (amplitude - 0.5) / 0.25;
        *r = t;
        *g = 1.0;
        *b = 0.0;
    } else {
        // Yellow to Red (0.75 - 1.0)
        CGFloat t = (amplitude - 0.75) / 0.25;
        *r = 1.0;
        *g = 1.0 - t;
        *b = 0.0;
    }
}

// Helper: Get rainbow color for position (0-1)
- (void)getRainbowColorForPosition:(CGFloat)position r:(CGFloat*)r g:(CGFloat*)g b:(CGFloat*)b {
    // HSV to RGB with hue cycling through rainbow
    CGFloat hue = fmod(position, 1.0);
    CGFloat saturation = 1.0;
    CGFloat value = 1.0;

    int hi = (int)(hue * 6.0) % 6;
    CGFloat f = hue * 6.0 - (int)(hue * 6.0);
    CGFloat p = value * (1.0 - saturation);
    CGFloat q = value * (1.0 - f * saturation);
    CGFloat t = value * (1.0 - (1.0 - f) * saturation);

    switch (hi) {
        case 0: *r = value; *g = t; *b = p; break;
        case 1: *r = q; *g = value; *b = p; break;
        case 2: *r = p; *g = value; *b = t; break;
        case 3: *r = p; *g = q; *b = value; break;
        case 4: *r = t; *g = p; *b = value; break;
        default: *r = value; *g = p; *b = q; break;
    }
}

// Envelope of one channel (0/1) or both mixed (-1), one value per pixel
// column. Wide views interpolate between buckets; narrow views merge them
// (max peak, RMS of RMS) so no bucket is lost or overdrawn.
static void computeColumns(const WaveformData& w, int channel, size_t cols,
                           std::vector<float>& peak, std::vector<float>& rms) {
    const size_t n = WaveformData::BUCKET_COUNT;
    peak.assign(cols, 0.0f);
    rms.assign(cols, 0.0f);
    if (cols == 0) return;

    auto bucketPeak = [&](size_t i) {
        auto p = [&](int ch) { return std::max(std::abs(w.min[ch][i]), std::abs(w.max[ch][i])); };
        if (channel >= 0) return p(channel);
        return w.channelCount == 2 ? std::max(p(0), p(1)) : p(0);
    };
    auto bucketRmsSq = [&](size_t i) {
        if (channel >= 0) return w.rms[channel][i] * w.rms[channel][i];
        if (w.channelCount == 2) return (w.rms[0][i] * w.rms[0][i] + w.rms[1][i] * w.rms[1][i]) * 0.5f;
        return w.rms[0][i] * w.rms[0][i];
    };

    const double bucketsPerCol = (double)n / cols;
    for (size_t c = 0; c < cols; ++c) {
        float p = 0.0f, r = 0.0f;
        if (bucketsPerCol >= 1.0) {
            const size_t b0 = (size_t)(c * bucketsPerCol);
            const size_t b1 = std::min(n, std::max(b0 + 1, (size_t)std::ceil((c + 1) * bucketsPerCol)));
            float sumSq = 0.0f;
            for (size_t i = b0; i < b1; ++i) {
                p = std::max(p, bucketPeak(i));
                sumSq += bucketRmsSq(i);
            }
            r = std::sqrt(sumSq / (b1 - b0));
        } else {
            const double t = std::clamp((c + 0.5) * bucketsPerCol - 0.5, 0.0, (double)(n - 1));
            const size_t i0 = (size_t)t, i1 = std::min(n - 1, i0 + 1);
            const float f = (float)(t - i0);
            p = bucketPeak(i0) + (bucketPeak(i1) - bucketPeak(i0)) * f;
            r = std::sqrt(bucketRmsSq(i0) + (bucketRmsSq(i1) - bucketRmsSq(i0)) * f);
        }
        peak[c] = std::min(1.0f, p);
        rms[c] = std::min(p, std::min(1.0f, r));   // RMS never exceeds the peak
    }
}

// Closed shape symmetric about centerY, one vertex per column center
static CGPathRef createEnvelopePath(const std::vector<float>& v, CGFloat centerY, CGFloat amplitude) {
    // Half a pixel minimum, so silence still reads as a 1 px center line
    const CGFloat minHalf = 0.5;
    CGMutablePathRef path = CGPathCreateMutable();
    const size_t cols = v.size();
    CGPathMoveToPoint(path, NULL, 0, centerY + std::max(minHalf, v[0] * amplitude));
    for (size_t c = 0; c < cols; ++c) {
        CGPathAddLineToPoint(path, NULL, c + 0.5, centerY + std::max(minHalf, v[c] * amplitude));
    }
    CGPathAddLineToPoint(path, NULL, cols, centerY + std::max(minHalf, v[cols - 1] * amplitude));
    CGPathAddLineToPoint(path, NULL, cols, centerY - std::max(minHalf, v[cols - 1] * amplitude));
    for (size_t c = cols; c-- > 0;) {
        CGPathAddLineToPoint(path, NULL, c + 0.5, centerY - std::max(minHalf, v[c] * amplitude));
    }
    CGPathAddLineToPoint(path, NULL, 0, centerY - std::max(minHalf, v[0] * amplitude));
    CGPathCloseSubpath(path);
    return path;
}

// Loudness scale: the RMS level that fills the full height, the track's 98th
// percentile, so a few loud moments don't flatten everything else. Taken over
// every channel drawn so stereo halves share one scale.
static float loudnessReference(const WaveformData& w, bool stereo) {
    std::vector<float> levels;
    levels.reserve(WaveformData::BUCKET_COUNT * 2);
    for (size_t i = 0; i < WaveformData::BUCKET_COUNT; ++i) {
        if (stereo) {
            levels.push_back(w.rms[0][i]);
            levels.push_back(w.rms[1][i]);
        } else if (w.channelCount == 2) {
            levels.push_back(std::sqrt((w.rms[0][i] * w.rms[0][i] + w.rms[1][i] * w.rms[1][i]) * 0.5f));
        } else {
            levels.push_back(w.rms[0][i]);
        }
    }
    auto nth = levels.begin() + levels.size() * 98 / 100;
    std::nth_element(levels.begin(), nth, levels.end());
    return std::max(1e-4f, *nth);
}

- (void)drawWaveformInContext:(CGContextRef)context bounds:(CGRect)bounds {
    const WaveformData* waveform = self.waveformData;
    if (!waveform || !waveform->isValid()) return;

    // Rendered once per track/size/settings; frames only redraw the overlay
    const CGSize pixelSize = [self convertSizeToBacking:bounds.size];
    const size_t pixelW = (size_t)std::lround(pixelSize.width);
    const size_t pixelH = (size_t)std::lround(pixelSize.height);
    if (pixelW == 0 || pixelH == 0) return;

    if (!_waveformImage || CGImageGetWidth(_waveformImage) != pixelW || CGImageGetHeight(_waveformImage) != pixelH) {
        CGImageRelease(_waveformImage);
        _waveformImage = [self createWaveformImageWidth:pixelW height:pixelH];
    }
    if (_waveformImage) {
        CGContextDrawImage(context, bounds, _waveformImage);
    }
}

- (void)invalidateWaveformImage {
    CGImageRelease(_waveformImage);
    _waveformImage = NULL;
}

- (void)setWaveformData:(const WaveformData *)waveformData {
    _waveformData = waveformData;
    [self invalidateWaveformImage];
}

- (CGImageRef)createWaveformImageWidth:(size_t)width height:(size_t)height {
    const WaveformData& waveform = *self.waveformData;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, width, height, 8, 0, colorSpace,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(colorSpace);
    if (!ctx) return NULL;

    const CGFloat scale = (CGFloat)height / std::max<CGFloat>(1.0, self.bounds.size.height);
    const CGFloat padding = 4.0 * scale;
    const bool isStereo = (waveform.channelCount == 2 && self.displayMode == WaveformDisplayModeStereo);
    const float loudnessRef = self.amplitudeScale == WaveformAmplitudeScaleLoudness
        ? loudnessReference(waveform, isStereo) : 0.0f;

    if (isStereo) {
        // Left channel on top, right below, each in its own half
        const CGFloat amplitude = height / 4.0 - padding;
        [self drawChannel:0 waveform:waveform loudnessRef:loudnessRef context:ctx width:width
                  centerY:height * 0.75 amplitude:amplitude];
        [self drawChannel:1 waveform:waveform loudnessRef:loudnessRef context:ctx width:width
                  centerY:height * 0.25 amplitude:amplitude];
    } else {
        [self drawChannel:-1 waveform:waveform loudnessRef:loudnessRef context:ctx width:width
                  centerY:height / 2.0 amplitude:height / 2.0 - padding];
    }

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}

// Peak scale: sample peaks, 1.0 = full scale. Loudness scale: RMS relative to
// loudnessRef, square-rooted so quiet passages keep visible height.
- (void)drawChannel:(int)channel waveform:(const WaveformData&)waveform loudnessRef:(float)loudnessRef
            context:(CGContextRef)ctx width:(size_t)width centerY:(CGFloat)centerY amplitude:(CGFloat)amplitude {
    std::vector<float> levels, rms;
    computeColumns(waveform, channel, width, levels, rms);
    if (loudnessRef > 0.0f) {
        for (size_t c = 0; c < width; ++c) levels[c] = std::sqrt(std::min(1.0f, rms[c] / loudnessRef));
    }

    if (self.waveformStyle == WaveformRenderStyleSolid) {
        NSColor *base = [self.waveformColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (!base) return;
        CGFloat rgb[3] = { base.redComponent, base.greenComponent, base.blueComponent };
        CGPathRef path = createEnvelopePath(levels, centerY, amplitude);
        [self fillPath:path context:ctx rgb:rgb alpha:base.alphaComponent centerY:centerY amplitude:amplitude];
        CGPathRelease(path);
        return;
    }

    // Heat map and Rainbow: a color per column
    for (size_t c = 0; c < width; ++c) {
        CGFloat r, g, b;
        if (self.waveformStyle == WaveformRenderStyleHeatMap) {
            [self getHeatMapColorForAmplitude:levels[c] r:&r g:&g b:&b];
        } else {
            [self getRainbowColorForPosition:(c + 0.5) / width r:&r g:&g b:&b];
        }
        const CGFloat half = std::max<CGFloat>(0.5, levels[c] * amplitude);
        CGContextSetRGBFillColor(ctx, r, g, b, 1.0);
        CGContextFillRect(ctx, CGRectMake(c, centerY - half, 1, half * 2));
    }
}

// Flat fill, or with gradient bands: alpha steps down from the center line
// to 40% at full amplitude, one step per band
- (void)fillPath:(CGPathRef)path context:(CGContextRef)ctx rgb:(const CGFloat *)rgb alpha:(CGFloat)alpha
         centerY:(CGFloat)centerY amplitude:(CGFloat)amplitude {
    const int bands = std::min(32, self.gradientBands);
    if (bands <= 0) {
        CGContextSetRGBFillColor(ctx, rgb[0], rgb[1], rgb[2], alpha);
        CGContextAddPath(ctx, path);
        CGContextFillPath(ctx);
        return;
    }

    // Symmetric stepped stops across [centerY - amplitude, centerY + amplitude]:
    // band k covers distance [k, k+1)/bands from the center
    std::vector<CGFloat> components, locations;
    auto addStop = [&](CGFloat location, CGFloat a) {
        components.insert(components.end(), { rgb[0], rgb[1], rgb[2], a });
        locations.push_back(location);
    };
    for (int k = bands - 1; k >= 0; --k) {           // bottom edge up to center
        const CGFloat a = alpha * (1.0 - (CGFloat)k / bands * 0.6);
        addStop(0.5 - (CGFloat)(k + 1) / bands * 0.5, a);
        addStop(0.5 - (CGFloat)k / bands * 0.5, a);
    }
    for (int k = 0; k < bands; ++k) {                // center up to top edge
        const CGFloat a = alpha * (1.0 - (CGFloat)k / bands * 0.6);
        addStop(0.5 + (CGFloat)k / bands * 0.5, a);
        addStop(0.5 + (CGFloat)(k + 1) / bands * 0.5, a);
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components.data(),
                                                                 locations.data(), locations.size());
    CGColorSpaceRelease(colorSpace);
    if (!gradient) return;

    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, centerY - amplitude), CGPointMake(0, centerY + amplitude),
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGContextRestoreGState(ctx);
    CGGradientRelease(gradient);
}

// Get animation frequency: uses BPM if sync enabled, otherwise returns default
- (CGFloat)animationFrequencyWithDefault:(CGFloat)defaultHz {
    if (self.bpmSync && self.trackBpm > 0) {
        // Convert BPM to Hz: BPM / 60 = beats per second
        return self.trackBpm / 60.0;
    }
    return defaultHz;
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
    CGFloat fadeWidth = MIN(bounds.size.width * 0.02, 10.0);

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
    CGFloat freq = [self animationFrequencyWithDefault:1.0] * 2.0 * M_PI;  // Default 1Hz
    CGFloat pulse = 0.5 + 0.5 * sin(time * freq);
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
    CGFloat freq = [self animationFrequencyWithDefault:1.5] * 2.0 * M_PI;  // Default 1.5Hz
    CGFloat breath = 0.5 + 0.5 * sin(time * freq);

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
        CGFloat phase = time * baseFreq * 2.0 * M_PI + i * 0.8;  // Different phase per band
        CGFloat shimmer = 0.5 + 0.5 * sin(phase);
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
    CGFloat normalizedPosition = location.x / self.bounds.size.width;
    normalizedPosition = MAX(0.0, MIN(1.0, normalizedPosition));

    double seekTime = normalizedPosition * self.trackDuration;

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
    // Seek forward 5 seconds
    if (self.trackDuration > 0) {
        double newPosition = MIN(1.0, self.playbackPosition + (5.0 / self.trackDuration));
        [self performSeekToTime:newPosition * self.trackDuration];
        return YES;
    }
    return NO;
}

- (BOOL)accessibilityPerformDecrement {
    // Seek backward 5 seconds
    if (self.trackDuration > 0) {
        double newPosition = MAX(0.0, self.playbackPosition - (5.0 / self.trackDuration));
        [self performSeekToTime:newPosition * self.trackDuration];
        return YES;
    }
    return NO;
}

@end
