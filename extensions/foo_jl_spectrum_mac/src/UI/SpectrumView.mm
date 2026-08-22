//
//  SpectrumView.mm
//  foo_jl_spectrum_mac
//

#import "SpectrumView.h"
#include "../Core/SpectrumConfig.h"
#include "../../../../shared/UIStyles.h"
#include <vector>

@implementation SpectrumView {
    std::vector<float> _bars;
    std::vector<float> _peaks;

    // Cached settings (refreshed via reloadSettings)
    int      _barStyle;
    int      _gapPercent;
    bool     _peakHold;
    bool     _showDbGuides;
    bool     _glass;
    uint32_t _barColorLight;
    uint32_t _bgColorLight;
    uint32_t _barColorDark;
    uint32_t _bgColorDark;
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
    _peakHold      = getConfigBool(kKeyPeakHold, kDefaultPeakHold);
    _showDbGuides  = getConfigBool(kKeyShowDbGuides, kDefaultShowDbGuides);
    _glass         = getConfigBool(kKeyGlassBackground, kDefaultGlassBackground);
    _barColorLight = (uint32_t)getConfigInt(kKeyBarColorLight, kDefaultBarColorLight);
    _bgColorLight  = (uint32_t)getConfigInt(kKeyBgColorLight, kDefaultBgColorLight);
    _barColorDark  = (uint32_t)getConfigInt(kKeyBarColorDark, kDefaultBarColorDark);
    _bgColorDark   = (uint32_t)getConfigInt(kKeyBgColorDark, kDefaultBgColorDark);
    [self setNeedsDisplay:YES];
}

- (void)setBarsData:(const float *)bars peaks:(const float *)peaks count:(NSInteger)count {
    if (count < 0) count = 0;
    _bars.assign(bars, bars + count);
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

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    const CGRect bounds = self.bounds;

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

    const CGFloat W = bounds.size.width;
    const CGFloat H = bounds.size.height;
    const CGFloat maxBarH = H - 2.0;

    // Reserve a right margin for the dB scale when it fits.
    const CGFloat dbMargin = 34.0;
    const BOOL drawGuides = _showDbGuides && (W > dbMargin + 40.0);
    const CGFloat plotW = drawGuides ? (W - dbMargin) : W;

    if (drawGuides) [self drawDbGuidesInRect:bounds plotWidth:plotW maxBarHeight:maxBarH context:ctx];

    const CGFloat slot = plotW / (CGFloat)n;
    CGFloat gap = slot * (_gapPercent / 100.0);
    if (gap > slot - 1.0) gap = slot - 1.0;
    if (gap < 0) gap = 0;
    const CGFloat barW = slot - gap;

    NSColor *base = [self barColor];

    for (NSInteger i = 0; i < n; ++i) {
        CGFloat v = _bars[i];
        if (v < 0) v = 0; else if (v > 1) v = 1;
        CGFloat h = v * maxBarH;
        CGFloat x = (CGFloat)i * slot + gap * 0.5;

        if (h >= 1.0) {
            CGRect r = CGRectMake(x, 0, barW, h);
            [self fillBar:r index:i count:n base:base value:v context:ctx];
        }

        // Peak cap
        if (_peakHold) {
            CGFloat pv = _peaks[i];
            if (pv < 0) pv = 0; else if (pv > 1) pv = 1;
            if (pv > 0.001) {
                CGFloat py = pv * maxBarH;
                CGRect cap = CGRectMake(x, py, barW, 2.0);
                CGContextSetFillColorWithColor(ctx, [[base blendedColorWithFraction:0.4 ofColor:[NSColor whiteColor]] CGColor]);
                CGContextFillRect(ctx, cap);
            }
        }
    }
}

- (void)fillBar:(CGRect)r
          index:(NSInteger)i
          count:(NSInteger)n
           base:(NSColor *)base
          value:(CGFloat)v
        context:(CGContextRef)ctx {
    using namespace spectrum_config;

    if (_barStyle == BarStyleSpectrum) {
        // Hue mapped across frequency: low = red/orange, high = violet.
        CGFloat hue = 0.75 * (CGFloat)i / (CGFloat)MAX(1, n - 1);  // 0..0.75
        NSColor *c = [NSColor colorWithHue:(0.66 - hue) < 0 ? 0 : (0.66 - hue)
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
        NSBezierPath *path = [NSBezierPath bezierPathWithRect:r];
        [grad drawInBezierPath:path angle:90.0];
        return;
    }

    // Solid
    CGContextSetFillColorWithColor(ctx, base.CGColor);
    CGContextFillRect(ctx, r);
}

- (void)drawDbGuidesInRect:(CGRect)bounds
                 plotWidth:(CGFloat)plotW
              maxBarHeight:(CGFloat)maxBarH
                   context:(CGContextRef)ctx {
    const float floorDb = spectrum_config::kDisplayFloorDb;
    const float ceilDb  = spectrum_config::kDisplayCeilDb;
    const float range   = ceilDb - floorDb;
    if (range <= 0) return;

    const int step = 10;  // dB between marks
    NSColor *lineColor = [[NSColor separatorColor] colorWithAlphaComponent:0.5];
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]
    };

    CGContextSetLineWidth(ctx, 1.0);
    CGContextSetStrokeColorWithColor(ctx, lineColor.CGColor);

    // Marks at each multiple of `step` inside (floor, ceil].
    int startDb = (int)(std::floor(ceilDb / step) * step);
    for (int db = startDb; db > (int)floorDb; db -= step) {
        CGFloat v = (db - floorDb) / range;
        CGFloat y = std::round(v * maxBarH) + 0.5;  // crisp 1px line

        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, 0, y);
        CGContextAddLineToPoint(ctx, plotW, y);
        CGContextStrokePath(ctx);

        NSString *label = [NSString stringWithFormat:@"%d", db];
        NSSize sz = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(plotW + 5, y - sz.height / 2) withAttributes:attrs];
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
