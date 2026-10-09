//
//  SpectrumView.mm
//  foo_jl_spectrum_mac
//

#import "SpectrumView.h"
#include "../Core/SpectrumConfig.h"
#include "../../../../shared/UIStyles.h"
#include <algorithm>
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
    bool     _autoBars;
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

    // Per-bar frequency labels (bars mode). Text and sizes are cached per bar
    // count; lane layout is recomputed each drawRect from the plot length.
    NSArray<NSString *> *_barLabels;
    CGFloat  _barLabelMaxW;
    CGFloat  _barLabelH;
    NSInteger _blLanes;    // 1 or 2 staggered rows/columns
    NSInteger _blStride;   // label every Nth bar
    CGFloat  _blLaneSize;  // row height (horizontal) or column width (vertical)

    // Frequency readout while the left mouse button is held.
    BOOL     _probing;
    NSPoint  _probePoint;
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
    _autoBars      = getConfigInt(kKeyBarCount, kDefaultBarCount) == kBarCountAuto;
    _gapPercent    = (int)getConfigInt(kKeyGapPercent, kDefaultGapPercent);
    _minHz         = (int)getConfigInt(kKeyMinHz, kDefaultMinHz);
    _maxHz         = (int)getConfigInt(kKeyMaxHz, kDefaultMaxHz);
    // Same clamps as SpectrumAnalyzer::configure(), so fractionForHz: cannot
    // divide by zero or take log10 of a non-positive bound.
    if (_minHz < 10) _minHz = 10;
    if (_maxHz <= _minHz + 100) _maxHz = _minHz + 100;
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
    _barLabels = nil;  // frequency range or scale may have changed
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

// Inverse of fractionForHz:.
- (double)hzForFraction:(CGFloat)t {
    if (_logScale) {
        double lo = std::log10((double)_minHz);
        double hi = std::log10((double)_maxHz);
        return std::pow(10.0, lo + (hi - lo) * t);
    }
    return _minHz + (double)(_maxHz - _minHz) * t;
}

#pragma mark - Drawing

// Map a frequency fraction (0..1) and magnitude (0..1) to a screen point,
// honoring the current orientation. Uses the transient plot geometry.
- (CGPoint)mapF:(CGFloat)f mag:(CGFloat)m {
    if (_vertical) return CGPointMake(_pOx + m * _pMag, _pOy + f * _pFreq);
    return CGPointMake(_pOx + f * _pFreq, _pOy + m * _pMag);
}

// The magnitude axis needs a wide margin for "-80dB" labels; the frequency
// axis a thin one. Which screen edge holds which depends on orientation.
static const CGFloat kDbThick = 34.0;    // along the magnitude axis
static const CGFloat kFreqThick = 13.0;  // along the frequency axis

// Plot length along the frequency axis. Only the dB-label margin shortens it
// (the frequency-label margin runs across the other axis), so it is known
// before bar labels are laid out.
- (CGFloat)freqAxisLengthForSize:(NSSize)size drawDb:(BOOL *)drawDb drawFreq:(BOOL *)drawFreq {
    const CGFloat W = size.width, H = size.height;
    if (_vertical) {
        *drawDb   = _showDbGuides && (H > 50.0);   // dB labels along the bottom
        *drawFreq = _showFreqAxis && (W > 80.0);   // freq labels along the right
        return H - (*drawDb ? kFreqThick : 0.0) - 2.0;
    }
    *drawDb   = _showDbGuides && (W > 80.0);       // dB labels along the right
    *drawFreq = _showFreqAxis && (H > 50.0);       // freq labels along the bottom
    return W - (*drawDb ? kDbThick : 0.0);
}

- (NSInteger)autoBarCount {
    BOOL drawDb, drawFreq;
    const CGFloat len = [self freqAxisLengthForSize:self.bounds.size drawDb:&drawDb drawFreq:&drawFreq];
    const NSInteger n = (NSInteger)std::floor(len / spectrum_config::kAutoBarPitch);
    return std::max<NSInteger>(16, std::min<NSInteger>(n, spectrum_config::kMaxBarCount));
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (_autoBars && [self.delegate respondsToSelector:@selector(spectrumView:autoBarCountChanged:)]) {
        [self.delegate spectrumView:self autoBarCountChanged:[self autoBarCount]];
    }
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

    BOOL drawDb, drawFreq;
    CGFloat rightMargin = 0, bottomMargin = 0;
    const CGFloat freqLen = [self freqAxisLengthForSize:bounds.size
                                                 drawDb:&drawDb
                                               drawFreq:&drawFreq];
    if (_vertical) bottomMargin = H - 2.0 - freqLen;
    else           rightMargin  = W - freqLen;

    // The frequency-label margin does not change the plot's length along the
    // frequency axis, so bar labels can be laid out against that length first.
    const BOOL barLabels = drawFreq && _drawMode == spectrum_config::DrawModeBars;
    CGFloat freqMargin = _vertical ? kDbThick : kFreqThick;
    if (barLabels) {
        if (freqLen <= 1.0) return;
        [self layoutBarLabelsForCount:n length:freqLen crossSpace:(_vertical ? W : H)];
        freqMargin = _blLanes * _blLaneSize + (_vertical ? 4.0 : 2.0);
    }
    if (drawFreq) {
        if (_vertical) rightMargin = freqMargin; else bottomMargin = freqMargin;
    }

    const CGFloat plotW = W - rightMargin;
    const CGFloat plotH = H - bottomMargin - 2.0;
    if (plotW <= 1.0 || plotH <= 1.0) return;

    _pOx = 0.0;
    _pOy = bottomMargin;
    _pFreq = _vertical ? plotH : plotW;
    _pMag  = _vertical ? plotW : plotH;

    // Grid behind the spectrum. In bars mode the bars themselves mark the
    // frequency axis, so each gets a label instead of frequency gridlines.
    if (barLabels)     [self drawBarLabelsCount:n];
    else if (drawFreq) [self drawFreqAxisInContext:ctx];
    if (drawDb)        [self drawDbGuidesInContext:ctx];

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

    if (_probing) [self drawProbeInContext:ctx];
}

#pragma mark - Bars

- (void)drawBarsBase:(NSColor *)base
              shadow:(NSColor *)shadowColor
                 cap:(NSColor *)capColor
               count:(NSInteger)n
             context:(CGContextRef)ctx {
    using namespace spectrum_config;
    const CGFloat slot = _pFreq / (CGFloat)n;
    CGFloat gap = slot * (_gapPercent / 100.0);
    if (gap > slot - 1.0) gap = slot - 1.0;
    if (gap < 0) gap = 0;

    // Snap bar edges to device pixels. With narrow slots (e.g. "Auto" at
    // 2pt/bar) a fractional gap is antialiased into two faint pixels or
    // vanishes depending on its sub-pixel phase, so neighbouring bars look
    // fused in a repeating pattern. Any non-zero gap is at least 1px wide.
    const CGFloat scale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 1.0;
    auto snap = [&](CGFloat v) { return std::round(v * scale) / scale; };
    const CGFloat px = 1.0 / scale;
    CGFloat gapSnapped = snap(gap);
    if (_gapPercent > 0 && gapSnapped < px) gapSnapped = px;
    const CGFloat gapLead = std::floor(gapSnapped * scale / 2.0) / scale;

    struct Span { CGFloat off, th; };
    std::vector<Span> spans((size_t)n);
    for (NSInteger i = 0; i < n; ++i) {
        const CGFloat a = snap((CGFloat)i * slot), b = snap((CGFloat)(i + 1) * slot);
        CGFloat off = a + gapLead, th = (b - a) - gapSnapped;
        if (th < px) { off = a; th = std::max(px, b - a); }  // too narrow for a gap
        spans[(size_t)i] = {off, th};
    }

    auto clamp01 = [](float v) -> CGFloat { return v < 0 ? 0 : (v > 1 ? 1 : v); };
    auto barRect = [&](NSInteger i, CGFloat m) {
        return [self barRectAtOffset:spans[(size_t)i].off thickness:spans[(size_t)i].th magnitude:m];
    };

    // Each layer is drawn for all bars before the next (bars never overlap),
    // and single-colour layers go out as one path fill. With an "Auto" bar
    // count there can be ~1000 bars per frame.
    if (_shadowFill) {
        CGContextBeginPath(ctx);
        for (NSInteger i = 0; i < n; ++i) {
            const CGFloat sv = clamp01(_shadow[i]);
            if (sv > clamp01(_bars[i]) + 0.005)
                CGContextAddRect(ctx, barRect(i, sv));
        }
        CGContextSetFillColorWithColor(ctx, shadowColor.CGColor);
        CGContextFillPath(ctx);
    }

    if (_barStyle == BarStyleGradient) {
        NSColor *lo = [base blendedColorWithFraction:0.55 ofColor:[NSColor blackColor]];
        NSColor *hi = [base blendedColorWithFraction:0.25 ofColor:[NSColor whiteColor]];
        NSGradient *grad = [[NSGradient alloc] initWithStartingColor:lo endingColor:hi];
        const CGFloat angle = _vertical ? 0.0 : 90.0;  // along the magnitude axis
        for (NSInteger i = 0; i < n; ++i) {
            const CGFloat bv = clamp01(_bars[i]);
            if (bv * _pMag >= 1.0)
                [grad drawInRect:barRect(i, bv) angle:angle];
        }
    } else if (_barStyle == BarStyleSpectrum) {
        const CGFloat brightness = fb2k_ui::isDarkMode() ? 1.0 : 0.9;
        for (NSInteger i = 0; i < n; ++i) {
            const CGFloat bv = clamp01(_bars[i]);
            if (bv * _pMag < 1.0) continue;
            CGFloat h = 0.66 - 0.75 * (CGFloat)i / (CGFloat)MAX(1, n - 1);
            if (h < 0) h = 0;
            NSColor *c = [NSColor colorWithHue:h saturation:0.85 brightness:brightness alpha:1.0];
            CGContextSetFillColorWithColor(ctx, c.CGColor);
            CGContextFillRect(ctx, barRect(i, bv));
        }
    } else {
        CGContextBeginPath(ctx);
        for (NSInteger i = 0; i < n; ++i) {
            const CGFloat bv = clamp01(_bars[i]);
            if (bv * _pMag >= 1.0)
                CGContextAddRect(ctx, barRect(i, bv));
        }
        CGContextSetFillColorWithColor(ctx, base.CGColor);
        CGContextFillPath(ctx);
    }

    if (_peakHold) {
        CGContextBeginPath(ctx);
        for (NSInteger i = 0; i < n; ++i) {
            const CGFloat pv = clamp01(_peaks[i]);
            if (pv > 0.001)
                CGContextAddRect(ctx, [self capRectAtOffset:spans[(size_t)i].off thickness:spans[(size_t)i].th magnitude:pv]);
        }
        CGContextSetFillColorWithColor(ctx, capColor.CGColor);
        CGContextFillPath(ctx);
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

// Curve knots sit at band centres ((i + 0.5) / n) so they line up with the
// frequency grid. The first and last bands are held flat out to the plot
// edges (0 and 1) so the curve spans the full width instead of stopping
// half a band short at each end. Knots are in (frequency, magnitude) space;
// mapF:mag: is affine, so Bezier control points map through it unchanged.
- (std::vector<CGPoint>)curveKnotsForValues:(const std::vector<float> &)v {
    std::vector<CGPoint> k;
    const NSInteger n = (NSInteger)v.size();
    if (n <= 0) return k;
    auto clamped = [&](NSInteger i) -> CGFloat {
        CGFloat m = v[i]; return m < 0 ? 0 : (m > 1 ? 1 : m);
    };
    k.reserve(n + 2);
    k.push_back(CGPointMake(0.0, clamped(0)));
    for (NSInteger i = 0; i < n; ++i) {
        k.push_back(CGPointMake(((CGFloat)i + 0.5) / n, clamped(i)));
    }
    k.push_back(CGPointMake(1.0, clamped(n - 1)));
    return k;
}

// Append a smooth curve through the knots, assuming the path's current point
// is already at k[0]. Uses Steffen's monotone cubic tangents: the curve never
// overshoots past neighbouring knots, so peaks stay where the data puts them
// and the curve cannot leave the 0..1 magnitude range.
- (void)appendSmoothCurve:(const std::vector<CGPoint> &)k toPath:(NSBezierPath *)p {
    const size_t n = k.size();
    if (n < 2) return;

    std::vector<CGFloat> slope(n - 1), tangent(n, 0.0);
    for (size_t i = 0; i + 1 < n; ++i) {
        const CGFloat h = k[i + 1].x - k[i].x;
        slope[i] = h > 0 ? (k[i + 1].y - k[i].y) / h : 0.0;
    }
    tangent[0] = slope[0];
    tangent[n - 1] = slope[n - 2];
    for (size_t i = 1; i + 1 < n; ++i) {
        const CGFloat s0 = slope[i - 1], s1 = slope[i];
        if (s0 * s1 <= 0) continue;  // local extremum or flat: zero tangent
        const CGFloat h0 = k[i].x - k[i - 1].x, h1 = k[i + 1].x - k[i].x;
        const CGFloat pm = (s0 * h1 + s1 * h0) / (h0 + h1);
        const CGFloat lim = std::min({std::fabs(s0), std::fabs(s1), 0.5 * std::fabs(pm)});
        tangent[i] = (s0 > 0 ? 2.0 : -2.0) * lim;
    }

    for (size_t i = 0; i + 1 < n; ++i) {
        const CGFloat h3 = (k[i + 1].x - k[i].x) / 3.0;
        [p curveToPoint:[self mapF:k[i + 1].x mag:k[i + 1].y]
          controlPoint1:[self mapF:k[i].x + h3 mag:k[i].y + tangent[i] * h3]
          controlPoint2:[self mapF:k[i + 1].x - h3 mag:k[i + 1].y - tangent[i + 1] * h3]];
    }
}

- (NSBezierPath *)areaPathForValues:(const std::vector<float> &)v {
    NSBezierPath *p = [NSBezierPath bezierPath];
    const std::vector<CGPoint> k = [self curveKnotsForValues:v];
    if (k.empty()) return p;
    [p moveToPoint:[self mapF:0.0 mag:0.0]];
    [p lineToPoint:[self mapF:k[0].x mag:k[0].y]];
    [self appendSmoothCurve:k toPath:p];
    [p lineToPoint:[self mapF:1.0 mag:0.0]];
    [p closePath];
    return p;
}

- (NSBezierPath *)linePathForValues:(const std::vector<float> &)v {
    NSBezierPath *p = [NSBezierPath bezierPath];
    const std::vector<CGPoint> k = [self curveKnotsForValues:v];
    if (k.empty()) return p;
    [p moveToPoint:[self mapF:k[0].x mag:k[0].y]];
    [self appendSmoothCurve:k toPath:p];
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

    const std::vector<double> ticks = [self freqAxisTicks];
    if (ticks.empty()) return;

    for (double f : ticks) {
        const CGFloat a = std::round(_pFreq * [self fractionForHz:f]) + 0.5;
        CGContextBeginPath(ctx);
        if (_vertical) {
            CGContextMoveToPoint(ctx, _pOx, _pOy + a);
            CGContextAddLineToPoint(ctx, _pOx + _pMag, _pOy + a);
        } else {
            CGContextMoveToPoint(ctx, _pOx + a, _pOy);
            CGContextAddLineToPoint(ctx, _pOx + a, _pOy + _pMag);
        }
        CGContextStrokePath(ctx);
    }

    // Labels are centred on their line but clamped inside the plot, so the
    // range ends stay labelled. The top label is placed first and the rest
    // are skipped greedily wherever they would collide.
    struct Placed { NSString *label; NSSize size; CGFloat start, ext; };
    auto place = [&](double f) -> Placed {
        NSString *label = (f >= 1000.0)
            ? [NSString stringWithFormat:@"%gkHz", f / 1000.0]
            : [NSString stringWithFormat:@"%gHz", f];
        const NSSize sz = [label sizeWithAttributes:attrs];
        const CGFloat ext = _vertical ? sz.height : sz.width;
        CGFloat s = _pFreq * [self fractionForHz:f] - ext / 2;
        s = std::max<CGFloat>(0.0, std::min<CGFloat>(s, _pFreq - ext));
        return {label, sz, s, ext};
    };
    auto draw = [&](const Placed &p) {
        NSPoint at = _vertical ? NSMakePoint(_pOx + _pMag + 5, _pOy + p.start)
                               : NSMakePoint(_pOx + p.start, (_pOy - p.size.height) / 2 + 1);
        [p.label drawAtPoint:at withAttributes:attrs];
    };

    const CGFloat pad = _vertical ? 2.0 : 4.0;
    const Placed top = place(ticks.back());
    draw(top);

    CGFloat lastEnd = -1000.0;
    for (size_t i = 0; i + 1 < ticks.size(); ++i) {
        const Placed p = place(ticks[i]);
        if (p.start < lastEnd + pad || p.start + p.ext > top.start - pad) continue;
        draw(p);
        lastEnd = p.start + p.ext;
    }
}

// Gridline frequencies, ascending. Log scale uses 1..9 x 10^e, adding 1.5x
// (and 1.25x/1.75x) when the 1x..2x span is wide enough, so the top octave
// (10k-20k) is not left empty. Linear scale uses a round step ~50px apart.
- (std::vector<double>)freqAxisTicks {
    std::vector<double> ticks;
    if (_pFreq <= 1.0) return ticks;

    if (_logScale) {
        const double decades = std::log10((double)_maxHz) - std::log10((double)_minHz);
        const CGFloat oneToTwo = _pFreq * std::log10(2.0) / decades;
        std::vector<double> mant = {1, 2, 3, 4, 5, 6, 7, 8, 9};
        if (oneToTwo >= 48.0)  mant.push_back(1.5);
        if (oneToTwo >= 120.0) { mant.push_back(1.25); mant.push_back(1.75); }
        std::sort(mant.begin(), mant.end());

        for (int e = 1; e <= 5; ++e) {
            const double decade = std::pow(10.0, e);
            for (double m : mant) {
                const double f = m * decade;
                if (f < _minHz) continue;
                if (f > _maxHz) break;
                ticks.push_back(f);
            }
        }
    } else {
        const double target = (_maxHz - _minHz) * 50.0 / _pFreq;  // Hz per ~50px
        const double p = std::pow(10.0, std::floor(std::log10(target)));
        double step = 10.0 * p;
        for (double m : {1.0, 2.0, 5.0}) {
            if (m * p >= target) { step = m * p; break; }
        }
        for (double f = std::ceil(_minHz / step) * step; f <= _maxHz + 0.5; f += step) {
            ticks.push_back(f);
        }
    }
    return ticks;
}

#pragma mark - Bar labels

// Compact 3-significant-digit frequency in the style of hardware analyzers:
// 21.5, 147, 1k14, 12k5, 20k.
static NSString *compactHz(double f) {
    if (f <= 0) return @"0";
    const int digits = (int)std::floor(std::log10(f)) + 1;
    const double scale = std::pow(10.0, 3 - digits);
    f = std::round(f * scale) / scale;

    const bool kilo = f >= 1000.0;
    const double v = kilo ? f / 1000.0 : f;
    const int intDigits = v >= 100 ? 3 : (v >= 10 ? 2 : 1);
    NSString *s = [NSString stringWithFormat:@"%.*f", std::max(0, 3 - intDigits), v];
    if ([s containsString:@"."]) {
        while ([s hasSuffix:@"0"]) s = [s substringToIndex:s.length - 1];
        if ([s hasSuffix:@"."]) s = [s substringToIndex:s.length - 1];
    }
    if (!kilo) return s;
    return [s containsString:@"."] ? [s stringByReplacingOccurrencesOfString:@"." withString:@"k"]
                                   : [s stringByAppendingString:@"k"];
}

- (NSDictionary *)barLabelAttrs {
    return @{
        NSFontAttributeName: [NSFont systemFontOfSize:8 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [self gridLabelColor]
    };
}

// Label text matches the analyzer's band centres: geometric mean of the band
// edges on a log scale (fraction (i + 0.5) / n), arithmetic mean on linear.
- (void)ensureBarLabelsForCount:(NSInteger)n {
    if (_barLabels && (NSInteger)_barLabels.count == n) return;
    NSDictionary *attrs = [self barLabelAttrs];
    NSMutableArray<NSString *> *labels = [NSMutableArray arrayWithCapacity:n];
    CGFloat maxW = 0, h = 0;
    for (NSInteger i = 0; i < n; ++i) {
        NSString *s = compactHz([self hzForFraction:((CGFloat)i + 0.5) / n]);
        NSSize sz = [s sizeWithAttributes:attrs];
        maxW = MAX(maxW, sz.width);
        h = MAX(h, sz.height);
        [labels addObject:s];
    }
    _barLabels = labels;
    _barLabelMaxW = std::ceil(maxW);
    _barLabelH = std::ceil(h);
}

// One lane when every bar fits a label; otherwise two staggered lanes (as on
// RME DigiCheck) and, if still too dense, a label every Nth bar.
- (void)layoutBarLabelsForCount:(NSInteger)n length:(CGFloat)len crossSpace:(CGFloat)cross {
    [self ensureBarLabelsForCount:n];
    const CGFloat slot = len / (CGFloat)n;
    const CGFloat need = (_vertical ? _barLabelH : _barLabelMaxW + 3.0) + 1.0;
    const BOOL roomForTwo = cross >= (_vertical ? 160.0 : 90.0);

    _blLaneSize = _vertical ? _barLabelMaxW + 4.0 : _barLabelH;
    if (slot >= need || !roomForTwo) {
        _blLanes = 1;
        _blStride = (NSInteger)std::ceil(need / slot);
    } else {
        _blLanes = 2;
        _blStride = (NSInteger)std::ceil(need / (2.0 * slot));
    }
    if (_blStride < 1) _blStride = 1;
}

- (void)drawBarLabelsCount:(NSInteger)n {
    if ((NSInteger)_barLabels.count != n) return;
    NSDictionary *attrs = [self barLabelAttrs];
    const CGFloat slot = _pFreq / (CGFloat)n;
    CGFloat laneEnd[2] = {-1000.0, -1000.0};

    for (NSInteger i = 0, k = 0; i < n; i += _blStride, ++k) {
        NSString *label = _barLabels[i];
        NSSize sz = [label sizeWithAttributes:attrs];
        const CGFloat ext = _vertical ? sz.height : sz.width;
        const NSInteger lane = _blLanes > 1 ? (k % 2) : 0;

        // Centre on the bar, clamp inside the plot, skip on collision.
        CGFloat s = ((CGFloat)i + 0.5) * slot - ext / 2;
        s = std::max<CGFloat>(0.0, std::min<CGFloat>(s, _pFreq - ext));
        if (s < laneEnd[lane] + 1.0) continue;
        laneEnd[lane] = s + ext;

        NSPoint p;
        if (_vertical) {
            p = NSMakePoint(_pOx + _pMag + 4.0 + lane * _blLaneSize, _pOy + s);
        } else {
            p = NSMakePoint(_pOx + s, _pOy - 1.0 - (lane + 1) * _blLaneSize);
        }
        [label drawAtPoint:p withAttributes:attrs];
    }
}

#pragma mark - Frequency probe

// Exact readout for the probe; finer than the axis/bar labels.
static NSString *probeHz(double f) {
    if (f >= 1000.0) return [NSString stringWithFormat:@"%.2f kHz", f / 1000.0];
    if (f >= 100.0)  return [NSString stringWithFormat:@"%.0f Hz", f];
    return [NSString stringWithFormat:@"%.1f Hz", f];
}

// Marker line across the magnitude axis at the cursor's frequency, plus a
// label box beside the cursor (flipped to stay inside the view).
- (void)drawProbeInContext:(CGContextRef)ctx {
    if (_pFreq <= 1.0) return;
    const CGFloat along = _vertical ? _probePoint.y - _pOy : _probePoint.x - _pOx;
    CGFloat t = along / _pFreq;
    if (t < 0) t = 0; else if (t > 1) t = 1;

    const BOOL dark = fb2k_ui::isDarkMode();
    NSColor *ink = dark ? [NSColor whiteColor] : [NSColor blackColor];

    // Pixel-aligned 1px line.
    CGPoint a = [self mapF:t mag:0.0], b = [self mapF:t mag:1.0];
    if (_vertical) { a.y = b.y = std::round(a.y) + 0.5; }
    else           { a.x = b.x = std::round(a.x) + 0.5; }
    CGContextSetLineWidth(ctx, 1.0);
    CGContextSetStrokeColorWithColor(ctx, [ink colorWithAlphaComponent:0.7].CGColor);
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, a.x, a.y);
    CGContextAddLineToPoint(ctx, b.x, b.y);
    CGContextStrokePath(ctx);

    NSString *text = probeHz([self hzForFraction:t]);
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: ink
    };
    const NSSize sz = [text sizeWithAttributes:attrs];
    const CGFloat padX = 5.0, padY = 2.0, off = 10.0;
    const CGFloat bw = sz.width + 2 * padX, bh = sz.height + 2 * padY;
    const CGRect bounds = self.bounds;

    CGFloat x = _probePoint.x + off, y = _probePoint.y + off;
    if (x + bw > NSMaxX(bounds)) x = _probePoint.x - off - bw;
    if (y + bh > NSMaxY(bounds)) y = _probePoint.y - off - bh;
    x = std::max<CGFloat>(NSMinX(bounds), std::min<CGFloat>(x, NSMaxX(bounds) - bw));
    y = std::max<CGFloat>(NSMinY(bounds), std::min<CGFloat>(y, NSMaxY(bounds) - bh));

    NSRect box = NSMakeRect(x, y, bw, bh);
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3];
    NSColor *fill = dark ? [NSColor colorWithWhite:0.12 alpha:0.9]
                         : [NSColor colorWithWhite:0.97 alpha:0.9];
    [fill setFill];
    [bg fill];
    [[ink colorWithAlphaComponent:0.25] setStroke];
    bg.lineWidth = 1.0;
    [bg stroke];
    [text drawAtPoint:NSMakePoint(x + padX, y + padY) withAttributes:attrs];
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

#pragma mark - Mouse

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

// Hold the left button to read the frequency under the cursor; drag to scrub.
- (void)mouseDown:(NSEvent *)event {
    if (event.modifierFlags & NSEventModifierFlagControl) {
        [self rightMouseDown:event];  // ctrl-click opens the context menu
        return;
    }
    _probing = YES;
    _probePoint = [self convertPoint:event.locationInWindow fromView:nil];
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_probing) return;
    _probePoint = [self convertPoint:event.locationInWindow fromView:nil];
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    if (!_probing) return;
    _probing = NO;
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
