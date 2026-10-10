//
//  VectorscopeView.mm
//  foo_jl_vectorscope_mac
//

#import "VectorscopeView.h"
#include "../Core/VectorscopeConfig.h"
#include "../Core/PhosphorBuffer.h"
#include "../../../../shared/UIStyles.h"
#include <algorithm>
#include <cmath>

namespace {
    const CGFloat kPad = 6.0;           // around the scope square
    const CGFloat kLabelInset = 14.0;   // room for L / R / M / S outside the diamond
    const CGFloat kMinLabelSide = 120.0;
    const CGFloat kMinCorrSize = 90.0;  // panel smaller than this: scope only
    const CGFloat kCorrPad = 6.0;
    const CGFloat kBarHeight = 6.0;
    const CGFloat kRowPitch = 11.0;
    const CGFloat kScaleHeight = 12.0;  // "-1  0  +1" under the bars
    const CGFloat kRowLabelWidth = 26.0;
    const CGFloat kReadoutWidth = 38.0;

    // Trace image resolution: device pixels, in steps so a live resize does
    // not reallocate (and clear) the afterglow on every mouse move.
    const NSInteger kTraceStep = 16;
    const NSInteger kTraceMinSide = 32;
    const NSInteger kTraceMaxSide = 1024;

    // Bars ease to new readings over this long.
    const double kBarEase = 0.08;

    const int kMaxRows = 3;
}

@implementation VectorscopeView {
    PhosphorBuffer _phosphor;
    uint32_t _lut[256];
    bool     _lutDirty;
    bool     _traceEmpty;
    CALayer *_traceLayer;
    CGColorSpaceRef _colorSpace;

    // Cached settings (refreshed via reloadSettings)
    bool     _connect;
    double   _persistence;   // seconds
    float    _brightness;    // energy multiplier
    bool     _showCorrelation;
    bool     _bandMode;
    bool     _showGrid;
    bool     _showLabels;
    int      _gridOpacity;
    bool     _glass;
    uint32_t _traceColorLight, _bgColorLight, _gridColorLight;
    uint32_t _traceColorDark,  _bgColorDark,  _gridColorDark;

    // Layout (recomputed on resize / settings change)
    NSRect   _plotRect;      // square the diamond is inscribed in; empty = hidden
    NSRect   _corrRect;      // correlation strip along the bottom; empty = hidden
    bool     _labelsVisible;

    // Correlation rows: [0] broadband, or low / mid / high in band mode.
    float    _target[kMaxRows];
    bool     _targetSilent[kMaxRows];
    float    _shown[kMaxRows];
    bool     _shownSilent[kMaxRows];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        _colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        _traceEmpty = true;
        for (int i = 0; i < kMaxRows; ++i) {
            _target[i] = _shown[i] = 0.0f;
            _targetSilent[i] = _shownSilent[i] = true;
        }

        _traceLayer = [CALayer layer];
        _traceLayer.contentsGravity = kCAGravityResize;
        _traceLayer.magnificationFilter = kCAFilterLinear;
        _traceLayer.minificationFilter = kCAFilterLinear;
        // The image changes every frame; implicit cross-fades would smear it.
        _traceLayer.actions = @{ @"contents": [NSNull null], @"bounds": [NSNull null],
                                 @"position": [NSNull null], @"hidden": [NSNull null] };
        [self.layer addSublayer:_traceLayer];

        [self reloadSettings];
    }
    return self;
}

- (void)dealloc {
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
}

- (BOOL)isFlipped { return NO; }  // origin bottom-left: y grows upward like the scope

- (void)reloadSettings {
    using namespace vectorscope_config;
    _connect      = getConfigInt(kKeyDrawMode, kDefaultDrawMode) != DrawModeDots;
    _persistence  = getConfigIntClamped(kKeyPersistenceMs, kDefaultPersistenceMs,
                                        kMinPersistenceMs, kMaxPersistenceMs) / 1000.0;
    // 0-100 slider -> 0.1x .. 4x, exponential so each step looks even.
    _brightness   = 0.1f * std::pow(40.0f, getConfigIntClamped(kKeyBrightness, kDefaultBrightness, 0, 100) / 100.0f);
    _showCorrelation = getConfigBool(kKeyShowCorrelation, kDefaultShowCorrelation);
    _bandMode     = getConfigInt(kKeyCorrelationMode, kDefaultCorrelationMode) == CorrelationBands;
    _showGrid     = getConfigBool(kKeyShowGrid, kDefaultShowGrid);
    _showLabels   = getConfigBool(kKeyShowLabels, kDefaultShowLabels);
    _gridOpacity  = getConfigIntClamped(kKeyGridOpacity, kDefaultGridOpacity, 0, 100);
    _glass        = getConfigBool(kKeyGlassBackground, kDefaultGlassBackground);
    _traceColorLight = (uint32_t)getConfigInt(kKeyTraceColorLight, kDefaultTraceColorLight);
    _bgColorLight    = (uint32_t)getConfigInt(kKeyBgColorLight, kDefaultBgColorLight);
    _gridColorLight  = (uint32_t)getConfigInt(kKeyGridColorLight, kDefaultGridColorLight);
    _traceColorDark  = (uint32_t)getConfigInt(kKeyTraceColorDark, kDefaultTraceColorDark);
    _bgColorDark     = (uint32_t)getConfigInt(kKeyBgColorDark, kDefaultBgColorDark);
    _gridColorDark   = (uint32_t)getConfigInt(kKeyGridColorDark, kDefaultGridColorDark);
    _lutDirty = true;
    [self updateLayout];
    [self setNeedsDisplay:YES];
}

#pragma mark - Layout

- (NSInteger)rowCount { return _bandMode ? 3 : 1; }

- (void)updateLayout {
    const NSRect b = self.bounds;

    CGFloat corrH = 0.0;
    if (_showCorrelation && b.size.width >= kMinCorrSize && b.size.height >= kMinCorrSize) {
        corrH = kCorrPad + [self rowCount] * kRowPitch + (_showLabels ? kScaleHeight : 0.0) + kCorrPad;
    }
    _corrRect = NSMakeRect(0, 0, b.size.width, corrH);

    const CGFloat side = std::min(b.size.width, b.size.height - corrH) - 2.0 * kPad;
    _labelsVisible = _showLabels && side >= kMinLabelSide;
    const CGFloat r = std::floor(side / 2.0 - (_labelsVisible ? kLabelInset : 0.0));
    if (r < 8.0) {
        _plotRect = NSZeroRect;
    } else {
        const CGFloat cx = std::round(NSMidX(b));
        const CGFloat cy = std::round(corrH + (b.size.height - corrH) / 2.0);
        _plotRect = NSMakeRect(cx - r, cy - r, 2.0 * r, 2.0 * r);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _traceLayer.hidden = NSIsEmptyRect(_plotRect);
    _traceLayer.frame = _plotRect;
    [CATransaction commit];

    if (!NSIsEmptyRect(_plotRect)) {
        const CGFloat scale = self.window ? self.window.backingScaleFactor : 2.0;
        NSInteger px = (NSInteger)std::lround(_plotRect.size.width * scale / kTraceStep) * kTraceStep;
        px = std::max(kTraceMinSide, std::min(px, kTraceMaxSide));
        if (px != _phosphor.side()) {
            _phosphor.resize((int)px);
            _traceEmpty = true;
            _traceLayer.contents = nil;
        }
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updateLayout];
    [self setNeedsDisplay:YES];
}

// The trace resolution follows the screen's pixel density.
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateLayout];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateLayout];
}

#pragma mark - Color helpers

static NSColor *colorFromARGB(uint32_t argb) {
    return [NSColor colorWithSRGBRed:((argb >> 16) & 0xFF) / 255.0
                               green:((argb >> 8) & 0xFF) / 255.0
                                blue:(argb & 0xFF) / 255.0
                               alpha:((argb >> 24) & 0xFF) / 255.0];
}

- (uint32_t)traceARGB {
    return fb2k_ui::isDarkMode() ? _traceColorDark : _traceColorLight;
}

- (NSColor *)traceColor { return colorFromARGB([self traceARGB]); }

- (NSColor *)bgColor {
    return colorFromARGB(fb2k_ui::isDarkMode() ? _bgColorDark : _bgColorLight);
}

- (NSColor *)gridColor {
    return colorFromARGB(fb2k_ui::isDarkMode() ? _gridColorDark : _gridColorLight);
}

- (NSColor *)gridLineColor {
    return [[self gridColor] colorWithAlphaComponent:_gridOpacity / 100.0];
}

- (NSColor *)gridLabelColor {
    // Labels track opacity directly so 0% hides the grid entirely. A gentle
    // boost keeps them a touch more legible than the lines at low settings.
    CGFloat a = _gridOpacity / 100.0;
    if (a > 0.0) a = MIN(1.0, a * 1.4);
    return [[self gridColor] colorWithAlphaComponent:a];
}

- (NSDictionary *)labelAttrs {
    return @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [self gridLabelColor]
    };
}

#pragma mark - Trace

- (BOOL)advanceTrace:(const float *)xy
               count:(NSInteger)count
          sampleRate:(double)sampleRate
           deltaTime:(double)dt {
    [self easeBars:dt];

    if (NSIsEmptyRect(_plotRect) || _phosphor.side() < kTraceMinSide) return NO;
    if (!xy || sampleRate <= 0) count = 0;
    if (count <= 0 && _traceEmpty) return NO;

    const float remaining = _phosphor.decay((float)std::exp(-std::max(dt, 0.0) / _persistence));
    if (count > 0) {
        // Energy per sample, normalised so brightness does not depend on the
        // sample rate or the afterglow time, and only mildly on panel size.
        const double side = _phosphor.side();
        const float energy = (float)(_brightness * 2.0 * side * std::sqrt(side) / (sampleRate * _persistence));
        _phosphor.addTrace(xy, (size_t)count, energy, _connect);
    } else {
        _phosphor.breakTrace();
    }
    _traceEmpty = (count <= 0 && remaining <= 0.0f);

    [self presentTrace];
    return !_traceEmpty;
}

- (void)presentTrace {
    if (_traceEmpty) {
        _traceLayer.contents = nil;
        return;
    }
    if (_lutDirty) {
        // The white-hot core only reads as "brighter" on a dark background.
        buildPhosphorLUT([self traceARGB], fb2k_ui::isDarkMode(), _lut);
        _lutDirty = false;
    }

    const size_t side = (size_t)_phosphor.side();
    NSMutableData *pixels = [NSMutableData dataWithLength:side * side * 4];
    if (!pixels) return;
    _phosphor.render((uint8_t *)pixels.mutableBytes, _lut);

    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGImageRef image = CGImageCreate(side, side, 8, 32, side * 4, _colorSpace,
                                     (CGBitmapInfo)kCGImageAlphaPremultipliedLast,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!image) return;
    _traceLayer.contents = (__bridge id)image;
    CGImageRelease(image);
}

- (void)clearTrace {
    _phosphor.clear();
    _traceEmpty = true;
    _traceLayer.contents = nil;
    for (int i = 0; i < kMaxRows; ++i) {
        _target[i] = _shown[i] = 0.0f;
        _targetSilent[i] = _shownSilent[i] = true;
    }
    [self setNeedsDisplayInRect:_corrRect];
}

#pragma mark - Correlation

- (void)setCorrelation:(float)wide
                silent:(BOOL)wideSilent
                 bands:(const float *)bands
           bandsSilent:(const BOOL *)bandsSilent {
    for (int i = 0; i < kMaxRows; ++i) {
        const bool silent = _bandMode ? bandsSilent[i] : (i == 0 ? wideSilent : true);
        const float v = _bandMode ? bands[i] : (i == 0 ? wide : 0.0f);
        _targetSilent[i] = silent;
        _target[i] = silent ? 0.0f : std::max(-1.0f, std::min(1.0f, v));
    }
}

- (void)easeBars:(double)dt {
    const float k = (float)(1.0 - std::exp(-std::max(dt, 0.0) / kBarEase));
    bool changed = false;
    for (int i = 0; i < kMaxRows; ++i) {
        float next = _shown[i] + (_target[i] - _shown[i]) * k;
        if (std::fabs(_target[i] - next) < 0.002f) next = _target[i];
        // A silent row keeps its bar until it has eased back to the centre.
        const bool silent = _targetSilent[i] && next == 0.0f;
        if (next != _shown[i] || silent != _shownSilent[i]) changed = true;
        _shown[i] = next;
        _shownSilent[i] = silent;
    }
    if (changed && !NSIsEmptyRect(_corrRect)) [self setNeedsDisplayInRect:_corrRect];
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!_glass) {
        CGContextSetFillColorWithColor(ctx, [self bgColor].CGColor);
        CGContextFillRect(ctx, self.bounds);
    }

    if (!NSIsEmptyRect(_plotRect) && NSIntersectsRect(dirtyRect, NSInsetRect(_plotRect, -kLabelInset, -kLabelInset))) {
        if (_showGrid) [self drawGridInContext:ctx];
        if (_labelsVisible) [self drawAxisLabels];
    }
    if (!NSIsEmptyRect(_corrRect) && NSIntersectsRect(dirtyRect, _corrRect)) {
        [self drawCorrelationInContext:ctx];
    }
}

// Diamond = full scale at gain 1. Vertical axis is mid (L+R), horizontal is
// side (L-R); the diagonals are the left-only and right-only directions.
- (void)drawGridInContext:(CGContextRef)ctx {
    const CGFloat cx = NSMidX(_plotRect), cy = NSMidY(_plotRect);
    const CGFloat r = _plotRect.size.width / 2.0;

    CGContextSetLineWidth(ctx, 1.0);
    CGContextSetStrokeColorWithColor(ctx, [self gridLineColor].CGColor);

    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, cx, cy + r);
    CGContextAddLineToPoint(ctx, cx + r, cy);
    CGContextAddLineToPoint(ctx, cx, cy - r);
    CGContextAddLineToPoint(ctx, cx - r, cy);
    CGContextClosePath(ctx);
    // Mid and side axes
    CGContextMoveToPoint(ctx, cx + 0.5, cy - r);
    CGContextAddLineToPoint(ctx, cx + 0.5, cy + r);
    CGContextMoveToPoint(ctx, cx - r, cy + 0.5);
    CGContextAddLineToPoint(ctx, cx + r, cy + 0.5);
    // Left-only and right-only axes
    CGContextMoveToPoint(ctx, cx - r / 2, cy + r / 2);
    CGContextAddLineToPoint(ctx, cx + r / 2, cy - r / 2);
    CGContextMoveToPoint(ctx, cx + r / 2, cy + r / 2);
    CGContextAddLineToPoint(ctx, cx - r / 2, cy - r / 2);
    CGContextStrokePath(ctx);

    // Half scale (-6 dB), dashed
    const CGFloat dash[] = { 2.0, 3.0 };
    CGContextSaveGState(ctx);
    CGContextSetLineDash(ctx, 0, dash, 2);
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, cx, cy + r / 2);
    CGContextAddLineToPoint(ctx, cx + r / 2, cy);
    CGContextAddLineToPoint(ctx, cx, cy - r / 2);
    CGContextAddLineToPoint(ctx, cx - r / 2, cy);
    CGContextClosePath(ctx);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

- (void)drawAxisLabels {
    NSDictionary *attrs = [self labelAttrs];
    const CGFloat cx = NSMidX(_plotRect), cy = NSMidY(_plotRect);
    const CGFloat r = _plotRect.size.width / 2.0;

    auto drawCentered = [&](NSString *s, CGFloat x, CGFloat y) {
        const NSSize sz = [s sizeWithAttributes:attrs];
        [s drawAtPoint:NSMakePoint(x - sz.width / 2, y - sz.height / 2) withAttributes:attrs];
    };
    // Just outside the diamond: M above the top corner, S beside the side
    // corners, L / R off the middle of the upper edges.
    const CGFloat off = kLabelInset / 2.0;
    drawCentered(@"M", cx, cy + r + off);
    drawCentered(@"S", cx - r - off, cy);
    drawCentered(@"S", cx + r + off, cy);
    drawCentered(@"L", cx - r / 2 - off, cy + r / 2 + off);
    drawCentered(@"R", cx + r / 2 + off, cy + r / 2 + off);
}

- (void)drawCorrelationInContext:(CGContextRef)ctx {
    const NSInteger rows = [self rowCount];
    NSDictionary *attrs = [self labelAttrs];

    // Bars are as wide as the scope, but never cramped in a narrow panel.
    const CGFloat avail = _corrRect.size.width - 2.0 * kPad;
    const CGFloat width = std::min(avail, std::max<CGFloat>(_plotRect.size.width + 2.0 * kLabelInset, 220.0));
    const CGFloat left = std::round(NSMidX(_corrRect) - width / 2.0);
    const CGFloat barL = left + ((_bandMode && _showLabels) ? kRowLabelWidth : 0.0);
    const CGFloat barR = left + width - (_showLabels ? kReadoutWidth : 0.0);
    if (barR - barL < 20.0) return;
    const CGFloat mid = std::round((barL + barR) / 2.0);
    const CGFloat half = (barR - barL) / 2.0;

    NSColor *track = [[self gridColor] colorWithAlphaComponent:0.30];
    NSColor *positive = [self traceColor];
    NSColor *negative = [NSColor systemRedColor];
    NSColor *tick = [[self gridColor] colorWithAlphaComponent:0.9];
    static NSString * const kBandNames[3] = { @"Lo", @"Mid", @"Hi" };

    const CGFloat top = NSMaxY(_corrRect) - kCorrPad;
    for (NSInteger i = 0; i < rows; ++i) {
        const CGFloat y = top - (i + 1) * kRowPitch + (kRowPitch - kBarHeight) / 2.0;
        const CGRect bar = CGRectMake(barL, y, barR - barL, kBarHeight);
        CGContextSetFillColorWithColor(ctx, track.CGColor);
        CGContextFillRect(ctx, bar);

        const float v = _shown[i];
        if (!_shownSilent[i]) {
            const CGFloat x = mid + v * half;
            CGContextSetFillColorWithColor(ctx, (v >= 0 ? positive : negative).CGColor);
            CGContextFillRect(ctx, CGRectMake(std::min(mid, x), y, std::fabs(x - mid), kBarHeight));
            // Cursor stays visible when the reading sits at the centre.
            CGContextFillRect(ctx, CGRectMake(std::max(barL, std::min(barR - 2.0, x - 1.0)), y - 1.0, 2.0, kBarHeight + 2.0));
        }
        CGContextSetFillColorWithColor(ctx, tick.CGColor);
        CGContextFillRect(ctx, CGRectMake(mid - 0.5, y - 1.0, 1.0, kBarHeight + 2.0));

        if (_showLabels) {
            const CGFloat textY = y + kBarHeight / 2.0;
            if (_bandMode) {
                const NSSize sz = [kBandNames[i] sizeWithAttributes:attrs];
                [kBandNames[i] drawAtPoint:NSMakePoint(left, textY - sz.height / 2) withAttributes:attrs];
            }
            NSString *readout = _shownSilent[i] ? @"--" : [NSString stringWithFormat:@"%+.2f", v];
            const NSSize sz = [readout sizeWithAttributes:attrs];
            [readout drawAtPoint:NSMakePoint(left + width - sz.width, textY - sz.height / 2) withAttributes:attrs];
        }
    }

    if (_showLabels) {
        const CGFloat y = top - rows * kRowPitch - kScaleHeight + 1.0;
        NSString *lo = @"-1", *zero = @"0", *hi = @"+1";
        [lo drawAtPoint:NSMakePoint(barL, y) withAttributes:attrs];
        const NSSize zs = [zero sizeWithAttributes:attrs];
        [zero drawAtPoint:NSMakePoint(mid - zs.width / 2, y) withAttributes:attrs];
        const NSSize hs = [hi sizeWithAttributes:attrs];
        [hi drawAtPoint:NSMakePoint(barR - hs.width, y) withAttributes:attrs];
    }
}

#pragma mark - Appearance changes

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    _lutDirty = true;
    [self setNeedsDisplay:YES];
}

#pragma mark - Mouse

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)mouseDown:(NSEvent *)event {
    if (event.modifierFlags & NSEventModifierFlagControl) {
        [self rightMouseDown:event];  // ctrl-click opens the context menu
        return;
    }
    [super mouseDown:event];
}

#pragma mark - Context menu

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    if ([self.delegate respondsToSelector:@selector(vectorscopeViewRequestsContextMenu:atPoint:)]) {
        [self.delegate vectorscopeViewRequestsContextMenu:self atPoint:pt];
    } else {
        [super rightMouseDown:event];
    }
}

@end
