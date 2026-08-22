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
    int      _drawMode;
    bool     _vertical;
    int      _gapPercent;
    int      _minHz;
    int      _maxHz;
    bool     _logScale;

    // Transient plot geometry (set each drawRect). Frequency runs along one
    // axis, magnitude along the other, depending on orientation.
    CGFloat  _pOx, _pOy;   // plot origin (left, bottom)
    CGFloat  _pFreq;       // pixels along the frequency axis
    CGFloat  _pMag;        // pixels along the magnitude axis
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
    _drawMode      = (int)getConfigInt(kKeyDrawMode, kDefaultDrawMode);
    _vertical      = getConfigInt(kKeyOrientation, kDefaultOrientation) == OrientationVertical;
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

// Map a frequency fraction (0..1) and magnitude (0..1) to a screen point,
// honoring the current orientation. Uses the transient plot geometry.
- (CGPoint)mapF:(CGFloat)f mag:(CGFloat)m {
    if (_vertical) return CGPointMake(_pOx + m * _pMag, _pOy + f * _pFreq);
    return CGPointMake(_pOx + f * _pFreq, _pOy + m * _pMag);
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    const CGRect bounds = self.bounds;
    const CGFloat W = bounds.size.width;
    const CGFloat H = bounds.size.height;

    if (!_glass) {
        CGContextSetFillColorWithColor(ctx, [self bgColor].CGColor);
        CGContextFillRect(ctx, bounds);
    }

    const NSInteger n = (NSInteger)_bars.size();
    if (n <= 0) { [self drawPlaceholder:bounds]; return; }

    // The magnitude axis needs a wide margin for "-80dB" labels; the frequency
    // axis a thin one. Which screen edge holds which depends on orientation.
    const CGFloat dbThick = 34.0;    // along the magnitude axis
    const CGFloat freqThick = 13.0;  // along the frequency axis

    BOOL drawDb, drawFreq;
    CGFloat rightMargin = 0, bottomMargin = 0;
    if (_vertical) {
        drawDb   = _showDbGuides  && (H > 50.0);   // dB labels along the bottom
        drawFreq = _showFreqAxis  && (W > 80.0);   // freq labels along the right
        bottomMargin = drawDb   ? freqThick : 0.0;
        rightMargin  = drawFreq ? dbThick   : 0.0;
    } else {
        drawDb   = _showDbGuides  && (W > 80.0);   // dB labels along the right
        drawFreq = _showFreqAxis  && (H > 50.0);   // freq labels along the bottom
        rightMargin  = drawDb   ? dbThick   : 0.0;
        bottomMargin = drawFreq ? freqThick : 0.0;
    }

    const CGFloat plotW = W - rightMargin;
    const CGFloat plotH = H - bottomMargin - 2.0;
    if (plotW <= 1.0 || plotH <= 1.0) return;

    _pOx = 0.0;
    _pOy = bottomMargin;
    _pFreq = _vertical ? plotH : plotW;
    _pMag  = _vertical ? plotW : plotH;

    // Grid behind the spectrum.
    if (drawFreq) [self drawFreqAxisInContext:ctx];
    if (drawDb)   [self drawDbGuidesInContext:ctx];

    NSColor *base = [self barColor];
    const BOOL dark = fb2k_ui::isDarkMode();
    NSColor *shadowColor = [base blendedColorWithFraction:0.6 ofColor:[NSColor grayColor]];
    NSColor *capColor = dark ? [base blendedColorWithFraction:0.7 ofColor:[NSColor whiteColor]]
                             : [base blendedColorWithFraction:0.5 ofColor:[NSColor blackColor]];

    if (_drawMode == spectrum_config::DrawModeCurve) {
        [self drawCurveBase:base shadow:shadowColor cap:capColor context:ctx];
    } else {
        [self drawBarsBase:base shadow:shadowColor cap:capColor count:n context:ctx];
    }
}

#pragma mark - Bars

- (void)drawBarsBase:(NSColor *)base
              shadow:(NSColor *)shadowColor
                 cap:(NSColor *)capColor
               count:(NSInteger)n
             context:(CGContextRef)ctx {
    const CGFloat slot = _pFreq / (CGFloat)n;
    CGFloat gap = slot * (_gapPercent / 100.0);
    if (gap > slot - 1.0) gap = slot - 1.0;
    if (gap < 0) gap = 0;
    const CGFloat th = slot - gap;

    for (NSInteger i = 0; i < n; ++i) {
        const CGFloat off = (CGFloat)i * slot + gap * 0.5;

        CGFloat bv = _bars[i];  if (bv < 0) bv = 0; else if (bv > 1) bv = 1;

        if (_shadowFill) {
            CGFloat sv = _shadow[i]; if (sv < 0) sv = 0; else if (sv > 1) sv = 1;
            if (sv > bv + 0.005) {
                CGContextSetFillColorWithColor(ctx, shadowColor.CGColor);
                CGContextFillRect(ctx, [self barRectAtOffset:off thickness:th magnitude:sv]);
            }
        }

        if (bv * _pMag >= 1.0) {
            [self fillBarRect:[self barRectAtOffset:off thickness:th magnitude:bv]
                        index:i count:n base:base context:ctx];
        }

        if (_peakHold) {
            CGFloat pv = _peaks[i]; if (pv < 0) pv = 0; else if (pv > 1) pv = 1;
            if (pv > 0.001) {
                CGContextSetFillColorWithColor(ctx, capColor.CGColor);
                CGContextFillRect(ctx, [self capRectAtOffset:off thickness:th magnitude:pv]);
            }
        }
    }
}

// A bar filled from the baseline (magnitude 0) to `m`, `th` thick along freq.
- (CGRect)barRectAtOffset:(CGFloat)off thickness:(CGFloat)th magnitude:(CGFloat)m {
    if (_vertical) return CGRectMake(_pOx, _pOy + off, m * _pMag, th);
    return CGRectMake(_pOx + off, _pOy, th, m * _pMag);
}

// A thin peak cap at magnitude `m`.
- (CGRect)capRectAtOffset:(CGFloat)off thickness:(CGFloat)th magnitude:(CGFloat)m {
    if (_vertical) return CGRectMake(_pOx + m * _pMag, _pOy + off, 2.0, th);
    return CGRectMake(_pOx + off, _pOy + m * _pMag, th, 2.0);
}

- (void)fillBarRect:(CGRect)r
              index:(NSInteger)i
              count:(NSInteger)n
               base:(NSColor *)base
            context:(CGContextRef)ctx {
    using namespace spectrum_config;
    const CGFloat gradAngle = _vertical ? 0.0 : 90.0;  // along the magnitude axis

    if (_barStyle == BarStyleSpectrum) {
        CGFloat hue = 0.75 * (CGFloat)i / (CGFloat)MAX(1, n - 1);
        CGFloat h = (0.66 - hue); if (h < 0) h = 0;
        NSColor *c = [NSColor colorWithHue:h saturation:0.85
                               brightness:fb2k_ui::isDarkMode() ? 1.0 : 0.9 alpha:1.0];
        CGContextSetFillColorWithColor(ctx, c.CGColor);
        CGContextFillRect(ctx, r);
        return;
    }

    if (_barStyle == BarStyleGradient) {
        NSColor *lo = [base blendedColorWithFraction:0.55 ofColor:[NSColor blackColor]];
        NSColor *hi = [base blendedColorWithFraction:0.25 ofColor:[NSColor whiteColor]];
        NSGradient *grad = [[NSGradient alloc] initWithStartingColor:lo endingColor:hi];
        [grad drawInBezierPath:[NSBezierPath bezierPathWithRect:r] angle:gradAngle];
        return;
    }

    CGContextSetFillColorWithColor(ctx, base.CGColor);
    CGContextFillRect(ctx, r);
}

#pragma mark - Curve

- (void)drawCurveBase:(NSColor *)base
               shadow:(NSColor *)shadowColor
                  cap:(NSColor *)capColor
              context:(CGContextRef)ctx {
    // Shadow area behind, then the filled instantaneous curve, then peak line.
    if (_shadowFill) {
        [[shadowColor colorWithAlphaComponent:0.35] setFill];
        [[self areaPathForValues:_shadow] fill];
    }

    NSBezierPath *area = [self areaPathForValues:_bars];
    NSGradient *grad = [[NSGradient alloc]
        initWithStartingColor:[base colorWithAlphaComponent:0.10]
                  endingColor:[base colorWithAlphaComponent:0.65]];
    [grad drawInBezierPath:area angle:(_vertical ? 0.0 : 90.0)];

    NSBezierPath *line = [self linePathForValues:_bars];
    line.lineWidth = 1.5;
    [base setStroke];
    [line stroke];

    if (_peakHold) {
        NSBezierPath *peak = [self linePathForValues:_peaks];
        peak.lineWidth = 1.5;
        [capColor setStroke];
        [peak stroke];
    }
}

- (NSBezierPath *)areaPathForValues:(const std::vector<float> &)v {
    NSBezierPath *p = [NSBezierPath bezierPath];
    const NSInteger n = (NSInteger)v.size();
    if (n <= 0) return p;
    [p moveToPoint:[self mapF:0.5 / n mag:0.0]];
    for (NSInteger i = 0; i < n; ++i) {
        CGFloat m = v[i]; if (m < 0) m = 0; else if (m > 1) m = 1;
        [p lineToPoint:[self mapF:((CGFloat)i + 0.5) / n mag:m]];
    }
    [p lineToPoint:[self mapF:((CGFloat)n - 0.5) / n mag:0.0]];
    [p closePath];
    return p;
}

- (NSBezierPath *)linePathForValues:(const std::vector<float> &)v {
    NSBezierPath *p = [NSBezierPath bezierPath];
    const NSInteger n = (NSInteger)v.size();
    for (NSInteger i = 0; i < n; ++i) {
        CGFloat m = v[i]; if (m < 0) m = 0; else if (m > 1) m = 1;
        CGPoint pt = [self mapF:((CGFloat)i + 0.5) / n mag:m];
        if (i == 0) [p moveToPoint:pt]; else [p lineToPoint:pt];
    }
    return p;
}

#pragma mark - Grids

// dB guides: lines of constant magnitude across the frequency axis.
- (void)drawDbGuidesInContext:(CGContextRef)ctx {
    const float floorDb = spectrum_config::kDisplayFloorDb;
    const float ceilDb  = spectrum_config::kDisplayCeilDb;
    const float range   = ceilDb - floorDb;
    if (range <= 0) return;

    const int step = 10;
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [self gridLabelColor]
    };
    CGContextSetLineWidth(ctx, 1.0);
    CGContextSetStrokeColorWithColor(ctx, [self gridLineColor].CGColor);

    int startDb = (int)(std::floor(ceilDb / step) * step);
    for (int db = startDb; db > (int)floorDb; db -= step) {
        CGFloat v = (db - floorDb) / range;
        NSString *label = [NSString stringWithFormat:@"%ddB", db];
        NSSize sz = [label sizeWithAttributes:attrs];

        if (_vertical) {
            CGFloat x = std::round(_pOx + v * _pMag) + 0.5;
            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, x, _pOy);
            CGContextAddLineToPoint(ctx, x, _pOy + _pFreq);
            CGContextStrokePath(ctx);
            [label drawAtPoint:NSMakePoint(x - sz.width / 2, (_pOy - sz.height) / 2) withAttributes:attrs];
        } else {
            CGFloat y = std::round(_pOy + v * _pMag) + 0.5;
            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, _pOx, y);
            CGContextAddLineToPoint(ctx, _pOx + _pFreq, y);
            CGContextStrokePath(ctx);
            [label drawAtPoint:NSMakePoint(_pOx + _pFreq + 5, y - sz.height / 2) withAttributes:attrs];
        }
    }
}

// Frequency axis: lines of constant frequency across the magnitude axis.
- (void)drawFreqAxisInContext:(CGContextRef)ctx {
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:8 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [self gridLabelColor]
    };
    CGContextSetLineWidth(ctx, 1.0);
    CGContextSetStrokeColorWithColor(ctx, [self gridLineColor].CGColor);

    CGFloat lastLabelEdge = -1000.0;

    // Ticks at 1..9 x 10^e (10,20,..,90,100,..,900,1k,..,20k).
    for (int e = 1; e <= 5; ++e) {
        int decade = (int)std::pow(10.0, e);
        for (int m = 1; m <= 9; ++m) {
            double f = (double)m * decade;
            if (f < _minHz) continue;
            if (f > _maxHz) break;

            CGFloat frac = [self fractionForHz:f];
            if (frac < 0 || frac > 1) continue;

            NSString *label = (f >= 1000.0)
                ? [NSString stringWithFormat:@"%gkHz", f / 1000.0]
                : [NSString stringWithFormat:@"%dHz", (int)f];
            NSSize sz = [label sizeWithAttributes:attrs];

            if (_vertical) {
                CGFloat y = std::round(_pOy + frac * _pFreq) + 0.5;
                CGContextBeginPath(ctx);
                CGContextMoveToPoint(ctx, _pOx, y);
                CGContextAddLineToPoint(ctx, _pOx + _pMag, y);
                CGContextStrokePath(ctx);
                CGFloat ly = y - sz.height / 2;
                if (ly > lastLabelEdge + 2.0 && ly + sz.height < _pOy + _pFreq) {
                    [label drawAtPoint:NSMakePoint(_pOx + _pMag + 5, ly) withAttributes:attrs];
                    lastLabelEdge = ly + sz.height;
                }
            } else {
                CGFloat x = std::round(_pOx + frac * _pFreq) + 0.5;
                CGContextBeginPath(ctx);
                CGContextMoveToPoint(ctx, x, _pOy);
                CGContextAddLineToPoint(ctx, x, _pOy + _pMag);
                CGContextStrokePath(ctx);
                CGFloat lx = x - sz.width / 2;
                if (lx > lastLabelEdge + 4.0 && lx + sz.width < _pOx + _pFreq) {
                    [label drawAtPoint:NSMakePoint(lx, (_pOy - sz.height) / 2 + 1) withAttributes:attrs];
                    lastLabelEdge = lx + sz.width;
                }
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
