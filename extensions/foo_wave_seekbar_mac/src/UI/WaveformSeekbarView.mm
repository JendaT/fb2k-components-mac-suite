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
#include <cmath>

@interface WaveformSeekbarView () {
    NSTrackingArea *_trackingArea;
    const WaveformData *_cachedWaveform;
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
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    if (!context) return;

    CGRect bounds = self.bounds;

    // Draw background
    CGContextSetFillColorWithColor(context, self.backgroundColor.CGColor);
    CGContextFillRect(context, bounds);

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
    // Draw a placeholder message
    NSString *text = self.analyzing ? @"Analyzing..." : @"No waveform";
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
    };
    NSSize textSize = [text sizeWithAttributes:attributes];

    NSPoint point = NSMakePoint(
        (bounds.size.width - textSize.width) / 2,
        (bounds.size.height - textSize.height) / 2
    );

    [text drawAtPoint:point withAttributes:attributes];
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

- (void)drawWaveformInContext:(CGContextRef)context bounds:(CGRect)bounds {
    const WaveformData* waveform = self.waveformData;
    if (!waveform || !waveform->isValid()) return;

    uint32_t channels = waveform->channelCount;
    bool isStereo = (channels == 2 && self.displayMode == WaveformDisplayModeStereo);

    CGFloat viewWidth = bounds.size.width;
    CGFloat viewHeight = bounds.size.height;
    CGFloat padding = 4.0;

    // Get base color components (used for Solid style)
    NSColor *baseColor = [self.waveformColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!baseColor) baseColor = self.waveformColor;

    CGFloat baseR = baseColor.redComponent;
    CGFloat baseG = baseColor.greenComponent;
    CGFloat baseB = baseColor.blueComponent;

    // For Heat map and Rainbow, we draw per-bucket with individual colors
    // For Solid, we use gradient bands for the fade effect
    bool usePerBucketColor = (self.waveformStyle != WaveformRenderStyleSolid);

    if (usePerBucketColor) {
        // Heat map or Rainbow: draw each bucket with its own color
        CGContextSetLineWidth(context, 1.0);

        if (isStereo) {
            CGFloat quarterHeight = viewHeight / 4.0;
            CGFloat channelAmplitude = quarterHeight - padding;
            CGFloat leftCenterY = viewHeight * 0.75;
            CGFloat rightCenterY = viewHeight * 0.25;

            for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
                CGFloat x = (static_cast<CGFloat>(i) / WaveformData::BUCKET_COUNT) * viewWidth;
                CGFloat position = static_cast<CGFloat>(i) / WaveformData::BUCKET_COUNT;

                // Left channel
                CGFloat peakL = std::max(std::abs(waveform->min[0][i]), std::abs(waveform->max[0][i]));
                CGFloat rL, gL, bL;
                if (self.waveformStyle == WaveformRenderStyleHeatMap) {
                    [self getHeatMapColorForAmplitude:peakL r:&rL g:&gL b:&bL];
                } else {
                    [self getRainbowColorForPosition:position r:&rL g:&gL b:&bL];
                }
                CGContextSetRGBStrokeColor(context, rL, gL, bL, 1.0);
                CGContextBeginPath(context);
                CGContextMoveToPoint(context, x, leftCenterY - peakL * channelAmplitude);
                CGContextAddLineToPoint(context, x, leftCenterY + peakL * channelAmplitude);
                CGContextStrokePath(context);

                // Right channel
                CGFloat peakR = std::max(std::abs(waveform->min[1][i]), std::abs(waveform->max[1][i]));
                CGFloat rR, gR, bR;
                if (self.waveformStyle == WaveformRenderStyleHeatMap) {
                    [self getHeatMapColorForAmplitude:peakR r:&rR g:&gR b:&bR];
                } else {
                    [self getRainbowColorForPosition:position r:&rR g:&gR b:&bR];
                }
                CGContextSetRGBStrokeColor(context, rR, gR, bR, 1.0);
                CGContextBeginPath(context);
                CGContextMoveToPoint(context, x, rightCenterY - peakR * channelAmplitude);
                CGContextAddLineToPoint(context, x, rightCenterY + peakR * channelAmplitude);
                CGContextStrokePath(context);
            }
        } else {
            // Mono
            CGFloat midY = viewHeight / 2.0;
            CGFloat amplitude = (viewHeight / 2.0) - padding;

            for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
                CGFloat x = (static_cast<CGFloat>(i) / WaveformData::BUCKET_COUNT) * viewWidth;
                CGFloat position = static_cast<CGFloat>(i) / WaveformData::BUCKET_COUNT;

                CGFloat minVal, maxVal;
                if (channels == 1) {
                    minVal = waveform->min[0][i];
                    maxVal = waveform->max[0][i];
                } else {
                    minVal = (waveform->min[0][i] + waveform->min[1][i]) * 0.5f;
                    maxVal = (waveform->max[0][i] + waveform->max[1][i]) * 0.5f;
                }
                CGFloat peakVal = std::max(std::abs(minVal), std::abs(maxVal));

                CGFloat r, g, b;
                if (self.waveformStyle == WaveformRenderStyleHeatMap) {
                    [self getHeatMapColorForAmplitude:peakVal r:&r g:&g b:&b];
                } else {
                    [self getRainbowColorForPosition:position r:&r g:&g b:&b];
                }
                CGContextSetRGBStrokeColor(context, r, g, b, 1.0);
                CGContextBeginPath(context);
                CGContextMoveToPoint(context, x, midY - peakVal * amplitude);
                CGContextAddLineToPoint(context, x, midY + peakVal * amplitude);
                CGContextStrokePath(context);
            }
        }
    } else {
        // Solid style: use gradient bands for fade effect (original implementation)
        int gradientBands = MIN(32, self.gradientBands);  // Clamp to max 32
        CGFloat r = baseR, g = baseG, b = baseB;

        // If 0 bands, draw simple solid waveform without gradient
        if (gradientBands <= 0) {
            CGContextSetRGBStrokeColor(context, r, g, b, 1.0);
            CGContextSetLineWidth(context, 1.0);

            if (isStereo) {
                CGFloat quarterHeight = viewHeight / 4.0;
                CGFloat channelAmplitude = quarterHeight - padding;
                CGFloat leftCenterY = viewHeight * 0.75;
                CGFloat rightCenterY = viewHeight * 0.25;

                CGContextBeginPath(context);
                for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
                    CGFloat x = (static_cast<CGFloat>(i) / WaveformData::BUCKET_COUNT) * viewWidth;
                    CGFloat peakL = std::max(std::abs(waveform->min[0][i]), std::abs(waveform->max[0][i]));
                    CGFloat peakR = std::max(std::abs(waveform->min[1][i]), std::abs(waveform->max[1][i]));

                    CGContextMoveToPoint(context, x, leftCenterY - peakL * channelAmplitude);
                    CGContextAddLineToPoint(context, x, leftCenterY + peakL * channelAmplitude);
                    CGContextMoveToPoint(context, x, rightCenterY - peakR * channelAmplitude);
                    CGContextAddLineToPoint(context, x, rightCenterY + peakR * channelAmplitude);
                }
                CGContextStrokePath(context);
            } else {
                CGFloat midY = viewHeight / 2.0;
                CGFloat amplitude = (viewHeight / 2.0) - padding;

                CGContextBeginPath(context);
                for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
                    CGFloat x = (static_cast<CGFloat>(i) / WaveformData::BUCKET_COUNT) * viewWidth;
                    CGFloat minVal, maxVal;
                    if (channels == 1) {
                        minVal = waveform->min[0][i];
                        maxVal = waveform->max[0][i];
                    } else {
                        minVal = (waveform->min[0][i] + waveform->min[1][i]) * 0.5f;
                        maxVal = (waveform->max[0][i] + waveform->max[1][i]) * 0.5f;
                    }
                    CGFloat peakVal = std::max(std::abs(minVal), std::abs(maxVal));

                    CGContextMoveToPoint(context, x, midY - peakVal * amplitude);
                    CGContextAddLineToPoint(context, x, midY + peakVal * amplitude);
                }
                CGContextStrokePath(context);
            }
            return;
        }

        // Gradient bands rendering (gradientBands >= 2)

        if (isStereo) {
            CGFloat quarterHeight = viewHeight / 4.0;
            CGFloat channelAmplitude = quarterHeight - padding;

            // Left channel (top half)
            CGFloat leftCenterY = viewHeight * 0.75;
            for (int band = 0; band < gradientBands; band++) {
                CGFloat bandStart = (CGFloat)band / gradientBands;
                CGFloat bandEnd = (CGFloat)(band + 1) / gradientBands;
                CGFloat alpha = 1.0 - (bandStart * 0.6);

                CGContextSetRGBStrokeColor(context, r, g, b, alpha);
                CGContextSetLineWidth(context, 1.0);
                CGContextBeginPath(context);

                for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
                    CGFloat x = (static_cast<CGFloat>(i) / WaveformData::BUCKET_COUNT) * viewWidth;
                    CGFloat peakVal = std::max(std::abs(waveform->min[0][i]), std::abs(waveform->max[0][i]));

                    if (peakVal > bandStart) {
                        CGFloat drawPeak = std::min(peakVal, bandEnd);
                        CGFloat y1Top = leftCenterY + bandStart * channelAmplitude;
                        CGFloat y2Top = leftCenterY + drawPeak * channelAmplitude;
                        CGFloat y1Bot = leftCenterY - bandStart * channelAmplitude;
                        CGFloat y2Bot = leftCenterY - drawPeak * channelAmplitude;

                        CGContextMoveToPoint(context, x, y1Top);
                        CGContextAddLineToPoint(context, x, y2Top);
                        CGContextMoveToPoint(context, x, y1Bot);
                        CGContextAddLineToPoint(context, x, y2Bot);
                    }
                }
                CGContextStrokePath(context);
            }

            // Right channel (bottom half)
            CGFloat rightCenterY = viewHeight * 0.25;
            for (int band = 0; band < gradientBands; band++) {
                CGFloat bandStart = (CGFloat)band / gradientBands;
                CGFloat bandEnd = (CGFloat)(band + 1) / gradientBands;
                CGFloat alpha = 1.0 - (bandStart * 0.6);

                CGContextSetRGBStrokeColor(context, r, g, b, alpha);
                CGContextSetLineWidth(context, 1.0);
                CGContextBeginPath(context);

                for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
                    CGFloat x = (static_cast<CGFloat>(i) / WaveformData::BUCKET_COUNT) * viewWidth;
                    CGFloat peakVal = std::max(std::abs(waveform->min[1][i]), std::abs(waveform->max[1][i]));

                    if (peakVal > bandStart) {
                        CGFloat drawPeak = std::min(peakVal, bandEnd);
                        CGFloat y1Top = rightCenterY + bandStart * channelAmplitude;
                        CGFloat y2Top = rightCenterY + drawPeak * channelAmplitude;
                        CGFloat y1Bot = rightCenterY - bandStart * channelAmplitude;
                        CGFloat y2Bot = rightCenterY - drawPeak * channelAmplitude;

                        CGContextMoveToPoint(context, x, y1Top);
                        CGContextAddLineToPoint(context, x, y2Top);
                        CGContextMoveToPoint(context, x, y1Bot);
                        CGContextAddLineToPoint(context, x, y2Bot);
                    }
                }
                CGContextStrokePath(context);
            }
        } else {
            // Mono with gradient bands
            CGFloat midY = viewHeight / 2.0;
            CGFloat amplitude = (viewHeight / 2.0) - padding;

            for (int band = 0; band < gradientBands; band++) {
                CGFloat bandStart = (CGFloat)band / gradientBands;
                CGFloat bandEnd = (CGFloat)(band + 1) / gradientBands;
                CGFloat alpha = 1.0 - (bandStart * 0.6);

                CGContextSetRGBStrokeColor(context, r, g, b, alpha);
                CGContextSetLineWidth(context, 1.0);
                CGContextBeginPath(context);

                for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
                    CGFloat x = (static_cast<CGFloat>(i) / WaveformData::BUCKET_COUNT) * viewWidth;

                    CGFloat minVal, maxVal;
                    if (channels == 1) {
                        minVal = waveform->min[0][i];
                        maxVal = waveform->max[0][i];
                    } else {
                        minVal = (waveform->min[0][i] + waveform->min[1][i]) * 0.5f;
                        maxVal = (waveform->max[0][i] + waveform->max[1][i]) * 0.5f;
                    }

                    CGFloat peakVal = std::max(std::abs(minVal), std::abs(maxVal));

                    if (peakVal > bandStart) {
                        CGFloat drawPeak = std::min(peakVal, bandEnd);
                        CGFloat y1Top = midY - bandStart * amplitude;
                        CGFloat y2Top = midY - drawPeak * amplitude;
                        CGFloat y1Bot = midY + bandStart * amplitude;
                        CGFloat y2Bot = midY + drawPeak * amplitude;

                        CGContextMoveToPoint(context, x, y1Top);
                        CGContextAddLineToPoint(context, x, y2Top);
                        CGContextMoveToPoint(context, x, y1Bot);
                        CGContextAddLineToPoint(context, x, y2Bot);
                    }
                }
                CGContextStrokePath(context);
            }
        }
    }
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

    NSColor *bgDeviceColor = [self.backgroundColor colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
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

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) return;

    CGFloat components[8] = {
        bgColor.redComponent, bgColor.greenComponent, bgColor.blueComponent, dimOpacity,
        bgColor.redComponent, bgColor.greenComponent, bgColor.blueComponent, 0.0
    };

    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, NULL, 2);
    CGColorSpaceRelease(colorSpace);
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

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) return;

    // Glow uses waveform color
    NSColor *waveDeviceColor = [self.waveformColor colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (!waveDeviceColor) { CGColorSpaceRelease(colorSpace); return; }

    CGFloat glowAlpha = 0.3 + pulse * 0.4;  // 0.3-0.7 alpha
    CGFloat components[8] = {
        waveDeviceColor.redComponent, waveDeviceColor.greenComponent, waveDeviceColor.blueComponent, glowAlpha,
        waveDeviceColor.redComponent, waveDeviceColor.greenComponent, waveDeviceColor.blueComponent, 0.0
    };

    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, NULL, 2);
    CGColorSpaceRelease(colorSpace);
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
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) return;

    CGFloat components[8] = {
        bgColor.redComponent, bgColor.greenComponent, bgColor.blueComponent, dimOpacity,
        bgColor.redComponent, bgColor.greenComponent, bgColor.blueComponent, 0.0
    };

    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, NULL, 2);
    CGColorSpaceRelease(colorSpace);
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
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSeekToTime:seekTime];
        });
    }
}

- (void)performSeekToTime:(double)seekTime {
    try {
        auto pc = playback_control::get();
        if (pc.is_valid()) {
            pc->playback_seek(seekTime);
        }
    } catch (const std::exception& e) {
        pfc::string_formatter msg;
        msg << "[WaveSeek] Seek error: " << e.what();
        console::error(msg.c_str());
    } catch (...) {
        console::error("[WaveSeek] Unknown seek error");
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
