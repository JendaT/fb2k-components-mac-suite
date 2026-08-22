//
//  SpectrumView.mm
//  foo_jl_spectrum_mac
//

#import "SpectrumView.h"
#include "../Core/SpectrumConfig.h"
#include "../../../../shared/UIStyles.h"
#include <vector>
#include <cmath>

@implementation SpectrumView {
    std::vector<float> _bars;
    std::vector<float> _shadow;
    std::vector<float> _peaks;

    // Cached settings (refreshed via reloadSettings)
    int      _barStyle;
    int      _gapPercent;
    int      _minHz;
    int      _maxHz;
    bool     _logScale;
    bool     _peakHold;
    bool     _shadowFill;
    bool     _showDbGuides;
    bool     _showFreqAxis;
    int      _gridOpacity;
    bool     _glass;
    uint32_t _barColorLight;
    uint32_t _bgColorLight;
    uint32_t _barColorDark;
    uint32_t _bgColorDark;
    uint32_t _gridColorLight;
    uint32_t _gridColorDark;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        [self reloadSettings];
    }
    return self;
}

- (BOOL)isFlipped { return NO; }  // origin bottom-left: bars grow upward

- (void)reloadSettings {
    using namespace spectrum_config;
    _barStyle      = (int)getConfigInt(kKeyBarStyle, kDefaultBarStyle);
    _gapPercent    = (int)getConfigInt(kKeyGapPercent, kDefaultGapPercent);
    _minHz         = (int)getConfigInt(kKeyMinHz, kDefaultMinHz);
    _maxHz         = (int)getConfigInt(kKeyMaxHz, kDefaultMaxHz);
    _logScale      = getConfigInt(kKeyFreqScale, kDefaultFreqScale) == FreqScaleLog;
    _peakHold      = getConfigBool(kKeyPeakHold, kDefaultPeakHold);
    _shadowFill    = getConfigBool(kKeyShadowFill, kDefaultShadowFill);
    _showDbGuides  = getConfigBool(kKeyShowDbGuides, kDefaultShowDbGuides);
    _showFreqAxis  = getConfigBool(kKeyShowFreqAxis, kDefaultShowFreqAxis);
    _gridOpacity   = (int)getConfigInt(kKeyGridOpacity, kDefaultGridOpacity);
    _glass         = getConfigBool(kKeyGlassBackground, kDefaultGlassBackground);
    _barColorLight = (uint32_t)getConfigInt(kKeyBarColorLight, kDefaultBarColorLight);
    _bgColorLight  = (uint32_t)getConfigInt(kKeyBgColorLight, kDefaultBgColorLight);
    _barColorDark  = (uint32_t)getConfigInt(kKeyBarColorDark, kDefaultBarColorDark);
    _bgColorDark   = (uint32_t)getConfigInt(kKeyBgColorDark, kDefaultBgColorDark);
    _gridColorLight = (uint32_t)getConfigInt(kKeyGridColorLight, kDefaultGridColorLight);
    _gridColorDark  = (uint32_t)getConfigInt(kKeyGridColorDark, kDefaultGridColorDark);
    [self setNeedsDisplay:YES];
}

- (void)setBarsData:(const float *)bars
             shadow:(const float *)shadow
              peaks:(const float *)peaks
              count:(NSInteger)count {
    if (count < 0) count = 0;
    _bars.assign(bars, bars + count);
    _shadow.assign(shadow, shadow + count);
    _peaks.assign(peaks, peaks + count);
    [self setNeedsDisplay:YES];
}

#pragma mark - Color helpers

static NSColor *colorFromARGB(uint32_t argb) {
    return [NSColor colorWithSRGBRed:((argb >> 16) & 0xFF) / 255.0
                               green:((argb >> 8) & 0xFF) / 255.0
                                blue:(argb & 0xFF) / 255.0
                               alpha:((argb >> 24) & 0xFF) / 255.0];
}

- (NSColor *)barColor {
    return colorFromARGB(fb2k_ui::isDarkMode() ? _barColorDark : _barColorLight);
}

- (NSColor *)bgColor {
    return colorFromARGB(fb2k_ui::isDarkMode() ? _bgColorDark : _bgColorLight);
}

- (NSColor *)gridColor {
    return colorFromARGB(fb2k_ui::isDarkMode() ? _gridColorDark : _gridColorLight);
}

- (NSColor *)gridLineColor {
    CGFloat a = _gridOpacity / 100.0;
    if (a < 0) a = 0; else if (a > 1) a = 1;
    return [[self gridColor] colorWithAlphaComponent:a];
}

- (NSColor *)gridLabelColor {
    // Labels track opacity directly so 0% hides the grid entirely. A gentle
    // boost keeps them a touch more legible than the lines at low settings.
    CGFloat a = _gridOpacity / 100.0;
    if (a > 0.0) a = MIN(1.0, a * 1.4);
    return [[self gridColor] colorWithAlphaComponent:a];
}

// Fraction 0..1 across the plot width for a given frequency, matching the
// analyzer's band mapping so gridlines line up with the bars.
- (CGFloat)fractionForHz:(double)f {
    if (_logScale) {
        double lo = std::log10((double)_minHz);
        double hi = std::log10((double)_maxHz);
        return (CGFloat)((std::log10(f) - lo) / (hi - lo));
    }
    return (CGFloat)((f - _minHz) / (double)(_maxHz - _minHz));
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    const CGRect bounds = self.bounds;
    const CGFloat W = bounds.size.width;
    const CGFloat H = bounds.size.height;

    // Background
    if (!_glass) {
        CGContextSetFillColorWithColor(ctx, [self bgColor].CGColor);
        CGContextFillRect(ctx, bounds);
    }

    const NSInteger n = (NSInteger)_bars.size();
    if (n <= 0) {
        [self drawPlaceholder:bounds];
        return;
    }

    // Reserve margins: right for the dB scale, bottom for frequency labels.
    const CGFloat dbMargin = 34.0;
    const CGFloat freqMargin = 13.0;
    const BOOL drawDb   = _showDbGuides && (W > dbMargin + 40.0);
    const BOOL drawFreq = _showFreqAxis && (H > freqMargin + 30.0);

    const CGFloat plotW = drawDb ? (W - dbMargin) : W;
    const CGFloat plotBottom = drawFreq ? freqMargin : 0.0;
    const CGFloat plotH = H - plotBottom - 2.0;
    if (plotH <= 1.0) return;

    // Grid behind the bars.
    if (drawFreq) [self drawFreqAxisWithPlotWidth:plotW plotBottom:plotBottom plotHeight:plotH context:ctx];
    if (drawDb)   [self drawDbGuidesWithPlotWidth:plotW plotBottom:plotBottom plotHeight:plotH context:ctx];

    const CGFloat slot = plotW / (CGFloat)n;
    CGFloat gap = slot * (_gapPercent / 100.0);
    if (gap > slot - 1.0) gap = slot - 1.0;
    if (gap < 0) gap = 0;
    const CGFloat barW = slot - gap;

    NSColor *base = [self barColor];
    const BOOL dark = fb2k_ui::isDarkMode();
    // Shadow band: a muted grey-blue so it reads distinctly above the bar.
    NSColor *shadowColor = [base blendedColorWithFraction:0.6 ofColor:[NSColor grayColor]];
    // Peak line: high-contrast against the background in either theme.
    NSColor *capColor = dark ? [base blendedColorWithFraction:0.7 ofColor:[NSColor whiteColor]]
                             : [base blendedColorWithFraction:0.5 ofColor:[NSColor blackColor]];

    for (NSInteger i = 0; i < n; ++i) {
        CGFloat x = (CGFloat)i * slot + gap * 0.5;

        CGFloat bv = _bars[i];  if (bv < 0) bv = 0; else if (bv > 1) bv = 1;
        CGFloat barH = bv * plotH;

        // Shadow fill (slow-decaying) behind the bright bar.
        if (_shadowFill) {
            CGFloat sv = _shadow[i]; if (sv < 0) sv = 0; else if (sv > 1) sv = 1;
            CGFloat sh = sv * plotH;
            if (sh > barH + 0.5) {
                CGContextSetFillColorWithColor(ctx, shadowColor.CGColor);
                CGContextFillRect(ctx, CGRectMake(x, plotBottom, barW, sh));
            }
        }

        // Bright instantaneous bar.
        if (barH >= 1.0) {
            [self fillBar:CGRectMake(x, plotBottom, barW, barH) index:i count:n base:base context:ctx];
        }

        // Peak cap.
        if (_peakHold) {
            CGFloat pv = _peaks[i]; if (pv < 0) pv = 0; else if (pv > 1) pv = 1;
            if (pv > 0.001) {
                CGFloat py = plotBottom + pv * plotH;
                CGContextSetFillColorWithColor(ctx, capColor.CGColor);
                CGContextFillRect(ctx, CGRectMake(x, py, barW, 2.0));
            }
        }
    }
}

- (void)fillBar:(CGRect)r
          index:(NSInteger)i
          count:(NSInteger)n
           base:(NSColor *)base
        context:(CGContextRef)ctx {
    using namespace spectrum_config;

    if (_barStyle == BarStyleSpectrum) {
        // Hue mapped across frequency: low = blue, high = red.
        CGFloat hue = 0.75 * (CGFloat)i / (CGFloat)MAX(1, n - 1);
        CGFloat h = (0.66 - hue); if (h < 0) h = 0;
        NSColor *c = [NSColor colorWithHue:h
                               saturation:0.85
                               brightness:fb2k_ui::isDarkMode() ? 1.0 : 0.9
                                    alpha:1.0];
        CGContextSetFillColorWithColor(ctx, c.CGColor);
        CGContextFillRect(ctx, r);
        return;
    }

    if (_barStyle == BarStyleGradient) {
        NSColor *bottom = [base blendedColorWithFraction:0.55 ofColor:[NSColor blackColor]];
        NSColor *top = [base blendedColorWithFraction:0.25 ofColor:[NSColor whiteColor]];
        NSGradient *grad = [[NSGradient alloc] initWithStartingColor:bottom endingColor:top];
        [grad drawInBezierPath:[NSBezierPath bezierPathWithRect:r] angle:90.0];
        return;
    }

    // Solid
    CGContextSetFillColorWithColor(ctx, base.CGColor);
    CGContextFillRect(ctx, r);
}

#pragma mark - Grids

- (void)drawDbGuidesWithPlotWidth:(CGFloat)plotW
                       plotBottom:(CGFloat)plotBottom
                       plotHeight:(CGFloat)plotH
                          context:(CGContextRef)ctx {
    const float floorDb = spectrum_config::kDisplayFloorDb;
    const float ceilDb  = spectrum_config::kDisplayCeilDb;
    const float range   = ceilDb - floorDb;
    if (range <= 0) return;

    const int step = 10;
    NSColor *lineColor = [self gridLineColor];
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [self gridLabelColor]
    };

    CGContextSetLineWidth(ctx, 1.0);
    CGContextSetStrokeColorWithColor(ctx, lineColor.CGColor);

    int startDb = (int)(std::floor(ceilDb / step) * step);
    for (int db = startDb; db > (int)floorDb; db -= step) {
        CGFloat v = (db - floorDb) / range;
        CGFloat y = std::round(plotBottom + v * plotH) + 0.5;

        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, 0, y);
        CGContextAddLineToPoint(ctx, plotW, y);
        CGContextStrokePath(ctx);

        NSString *label = [NSString stringWithFormat:@"%ddB", db];
        NSSize sz = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(plotW + 5, y - sz.height / 2) withAttributes:attrs];
    }
}

- (void)drawFreqAxisWithPlotWidth:(CGFloat)plotW
                       plotBottom:(CGFloat)plotBottom
                       plotHeight:(CGFloat)plotH
                          context:(CGContextRef)ctx {
    NSColor *lineColor = [self gridLineColor];
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:8 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [self gridLabelColor]
    };

    CGContextSetLineWidth(ctx, 1.0);
    CGContextSetStrokeColorWithColor(ctx, lineColor.CGColor);

    CGFloat lastLabelRight = -1000.0;

    // Ticks at 1..9 x 10^e (10,20,..,90,100,..,900,1k,..,20k).
    for (int e = 1; e <= 5; ++e) {
        int decade = (int)std::pow(10.0, e);
        for (int m = 1; m <= 9; ++m) {
            double f = (double)m * decade;
            if (f < _minHz) continue;
            if (f > _maxHz) break;

            CGFloat frac = [self fractionForHz:f];
            if (frac < 0 || frac > 1) continue;
            CGFloat x = std::round(frac * plotW) + 0.5;

            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, x, plotBottom);
            CGContextAddLineToPoint(ctx, x, plotBottom + plotH);
            CGContextStrokePath(ctx);

            NSString *label = (f >= 1000.0)
                ? [NSString stringWithFormat:@"%gkHz", f / 1000.0]
                : [NSString stringWithFormat:@"%dHz", (int)f];
            NSSize sz = [label sizeWithAttributes:attrs];
            CGFloat lx = x - sz.width / 2;
            if (lx > lastLabelRight + 4.0 && lx + sz.width < plotW) {
                [label drawAtPoint:NSMakePoint(lx, (plotBottom - sz.height) / 2 + 1) withAttributes:attrs];
                lastLabelRight = lx + sz.width;
            }
        }
    }
}

- (void)drawPlaceholder:(CGRect)bounds {
    NSString *msg = @"Spectrum Analyzer";
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]
    };
    NSSize sz = [msg sizeWithAttributes:attrs];
    NSPoint p = NSMakePoint((bounds.size.width - sz.width) / 2,
                            (bounds.size.height - sz.height) / 2);
    [msg drawAtPoint:p withAttributes:attrs];
}

#pragma mark - Appearance changes

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

#pragma mark - Context menu

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    if ([self.delegate respondsToSelector:@selector(spectrumViewRequestsContextMenu:atPoint:)]) {
        [self.delegate spectrumViewRequestsContextMenu:self atPoint:pt];
    } else {
        [super rightMouseDown:event];
    }
}

@end
