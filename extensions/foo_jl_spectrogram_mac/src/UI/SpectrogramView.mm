//
//  SpectrogramView.mm
//  foo_jl_spectrogram_mac
//

#import "SpectrogramView.h"
#include "../Core/SpectrogramConfig.h"
#include "../Core/SpectrogramColormaps.h"
#include "../Core/SpectrogramEngine.h"
#include "../Core/SpectrogramThemes.h"
#include "../../../../shared/UIStyles.h"
#include "../../../../shared/ThemeColor.h"
#include <algorithm>
#include <cmath>
#include <deque>
#include <vector>

namespace {
    // The image is a strip of tiles this many columns wide. Only the newest
    // tile changes, so each frame uploads one small bitmap and moves the rest.
    const int kTileColumns = 256;

    // Right of the plot: a gap, the frequency labels, then the dB color scale
    // (bar, then its labels). Label widths follow the font size.
    const CGFloat kAxisGap = 6.0;      // plot edge to frequency labels
    const CGFloat kLegendGap = 8.0;    // frequency labels to the color bar
    const CGFloat kBarWidth = 7.0;
    const CGFloat kBarLabelGap = 5.0;  // color bar to its labels
    const CGFloat kEdgeGap = 4.0;      // labels to the panel's right edge

    // Label colors, as in the Spectrum Analyzer: the background pushed most
    // of the way to white (or black on a light background), decades further.
    const CGFloat kLabelInk = 0.62;
    const CGFloat kDecadeInk = 0.92;

    // Theme and panel colours are Display P3 (shared/ThemeColor.h).
    NSColor *colorFromARGB(uint32_t argb) {
        return JLColorFromARGB(argb);
    }

    // Mix in Display P3. blendedColorWithFraction: may convert to a
    // standard-gamut space first, which would clip saturated theme colours.
    NSColor *blendP3(NSColor *a, CGFloat fraction, NSColor *b) {
        NSColorSpace *p3 = [NSColorSpace displayP3ColorSpace];
        NSColor *x = [a colorUsingColorSpace:p3], *y = [b colorUsingColorSpace:p3];
        if (!x || !y) return nil;
        const CGFloat t = fraction < 0 ? 0 : (fraction > 1 ? 1 : fraction);
        return [NSColor colorWithDisplayP3Red:x.redComponent + (y.redComponent - x.redComponent) * t
                                        green:x.greenComponent + (y.greenComponent - x.greenComponent) * t
                                         blue:x.blueComponent + (y.blueComponent - x.blueComponent) * t
                                        alpha:x.alphaComponent + (y.alphaComponent - x.alphaComponent) * t];
    }

    NSFont *labelFont(CGFloat size, NSFontWeight weight) {
        NSFont *f = [NSFont monospacedSystemFontOfSize:size weight:weight];
        return f ?: [NSFont systemFontOfSize:size weight:weight];
    }

    bool isDecade(double hz) {
        const double e = std::log10(hz);
        return std::fabs(e - std::round(e)) < 1e-9;
    }

    // A new plot height is adopted once it has held this long. Until then the
    // existing tiles stretch, instead of a new tile per resize step.
    const CFTimeInterval kResizeSettle = 0.25;

    struct Tile {
        CALayer *layer = nil;
        int64_t  start = 0;         // index of the first column
        int      count = 0;         // columns written
        int      rows = 0;
        bool     dirty = false;
        std::vector<uint32_t> px;   // kTileColumns x rows, freed once the tile is full
    };

    void releasePixels(void *info, const void *data, size_t size) {
        free((void *)data);
    }
}

// Layer-hosting view holding the tile layers.
@interface SpectrogramPlotView : NSView
@end

@implementation SpectrogramPlotView
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        CALayer *root = [CALayer layer];
        root.masksToBounds = YES;
        // Adding or removing a sublayer would otherwise cross-fade the whole
        // picture for a quarter second each time a tile starts.
        root.actions = @{ @"sublayers": [NSNull null] };
        self.layer = root;
        self.wantsLayer = YES;
    }
    return self;
}
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

// Transparent view above the plot for the axis, gridlines, legend, and probe.
@interface SpectrogramOverlayView : NSView
@property (nonatomic, copy, nullable) void (^drawHandler)(void);
@end

@implementation SpectrogramOverlayView
- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)dirtyRect {
    if (self.drawHandler) self.drawHandler();
}
@end

@implementation SpectrogramView {
    SpectrogramPlotView *_plotView;
    SpectrogramOverlayView *_overlayView;

    std::deque<Tile> _tiles;        // oldest first; the last one is being filled
    int64_t  _columns;              // columns appended since the last clear
    CGFloat  _phase;                // sub-column shift of the picture, 0..1
    uint32_t _lut[spectrogram_colormap::kLutSize];
    CGColorSpaceRef _colorSpace;    // the LUT's: Display P3 or sRGB (isDisplayP3Map)
    bool     _lutIsP3;

    NSInteger _rows;                // rows columns are rendered at
    NSInteger _wantedRows;          // rows the current plot height asks for
    CFTimeInterval _wantedSince;

    // Cached settings (refreshed via reloadSettings)
    int      _scale;
    int      _minHz;
    int      _maxHz;
    int      _topDb;
    int      _rangeDb;
    int      _colormap;
    int      _gridOpacity;
    bool     _showFreqAxis;
    bool     _showLegend;
    CGFloat  _freqFontSize;
    CGFloat  _dbFontSize;
    uint32_t _bgColorLight;
    uint32_t _bgColorDark;
    uint32_t _gridColorLight;
    uint32_t _gridColorDark;
    uint32_t _accentColor;          // colormap's marker color (probe)

    // Layout (set in layoutPlot)
    NSRect   _plotRect;
    BOOL     _drawAxis;
    BOOL     _drawLegend;
    CGFloat  _axisWidth;            // gap plus frequency labels
    CGFloat  _legendWidth;          // color bar plus its labels
    std::vector<std::pair<int, NSString *>> _dbLabels;  // level and text, top first

    // Frequency readout while the left mouse button is held.
    BOOL     _probing;
    NSPoint  _probePoint;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        _scale = -1;  // no mapping yet, so the first reloadSettings does not clear

        _plotView = [[SpectrogramPlotView alloc] initWithFrame:self.bounds];
        [self addSubview:_plotView];

        _overlayView = [[SpectrogramOverlayView alloc] initWithFrame:self.bounds];
        __weak typeof(self) weakSelf = self;
        _overlayView.drawHandler = ^{ [weakSelf drawOverlay]; };
        [self addSubview:_overlayView];

        [self reloadSettings];
    }
    return self;
}

- (void)dealloc {
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
}

- (BOOL)isFlipped { return NO; }  // origin bottom-left: frequency grows upward

- (void)reloadSettings {
    using namespace spectrogram_config;
    const int scale = (int)getConfigInt(kKeyFreqScale, kDefaultFreqScale);
    const int minHz = (int)getConfigInt(kKeyMinHz, kDefaultMinHz);
    const int maxHz = std::max((int)getConfigInt(kKeyMaxHz, kDefaultMaxHz), minHz + 100);

    // History drawn under another frequency mapping would sit at the wrong
    // height against the new axis.
    if (_scale >= 0 && (scale != _scale || minHz != _minHz || maxHz != _maxHz)) [self clear];
    _scale = scale;
    _minHz = minHz;
    _maxHz = maxHz;

    _topDb        = (int)getConfigInt(kKeyTopDb, kDefaultTopDb);
    _rangeDb      = std::max(10, (int)getConfigInt(kKeyRangeDb, kDefaultRangeDb));
    _colormap     = (int)getConfigInt(kKeyColormap, kDefaultColormap);
    _gridOpacity  = (int)getConfigInt(kKeyGridOpacity, kDefaultGridOpacity);
    _showFreqAxis = getConfigBool(kKeyShowFreqAxis, kDefaultShowFreqAxis);
    _showLegend   = getConfigBool(kKeyShowLegend, kDefaultShowLegend);
    _freqFontSize = std::clamp((int)getConfigInt(kKeyFreqFontSize, kDefaultFreqFontSize), kMinFontSize, kMaxFontSize);
    _dbFontSize   = std::clamp((int)getConfigInt(kKeyDbFontSize, kDefaultDbFontSize), kMinFontSize, kMaxFontSize);
    _bgColorLight   = (uint32_t)getConfigInt(kKeyBgColorLight, kDefaultBgColorLight);
    _bgColorDark    = (uint32_t)getConfigInt(kKeyBgColorDark, kDefaultBgColorDark);
    _gridColorLight = (uint32_t)getConfigInt(kKeyGridColorLight, kDefaultGridColorLight);
    _gridColorDark  = (uint32_t)getConfigInt(kKeyGridColorDark, kDefaultGridColorDark);

    if (_colormap == spectrogram_colormap::kCustomMap) {
        uint32_t colors[spectrogram_colormap::kCustomColorCount];
        for (int i = 0; i < spectrogram_colormap::kCustomColorCount; ++i) colors[i] = customColor(i);
        spectrogram_colormap::buildCustomLut(colors, _lut);
    } else {
        spectrogram_colormap::buildLut(_colormap, _lut);
    }

    _accentColor = spectrogram_colormap::accentColor(_lut);

    // Tiles, the legend, and the probe draw the LUT in its own color space.
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
    _lutIsP3 = spectrogram_colormap::isDisplayP3Map(_colormap);
    _colorSpace = _lutIsP3 ? JLCreateThemeColorSpace() : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    // The not-yet-filled part of the plot reads as silence.
    _plotView.layer.backgroundColor = [self colorForLevel:0.0].CGColor;
    [self setNeedsDisplay:YES];

    [self layoutPlot];
}

// The margins around the plot take the panel background, not the colormap's
// floor: some colormaps start at a strong color (Viridis: purple).
- (BOOL)wantsUpdateLayer { return YES; }

- (void)updateLayer {
    self.layer.backgroundColor = [self bgColor].CGColor;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
    [_overlayView setNeedsDisplay:YES];
}

- (NSColor *)bgColor {
    return colorFromARGB(fb2k_ui::isDarkMode() ? _bgColorDark : _bgColorLight);
}

- (NSColor *)gridLineColor {
    NSColor *c = colorFromARGB(fb2k_ui::isDarkMode() ? _gridColorDark : _gridColorLight);
    return [c colorWithAlphaComponent:std::clamp(_gridOpacity, 0, 100) / 100.0];
}

// White on a dark background, black on a light one.
- (NSColor *)inkColor {
    NSColor *bg = [[self bgColor] colorUsingColorSpace:[NSColorSpace displayP3ColorSpace]];
    if (!bg) return NSColor.labelColor;
    const CGFloat luminance = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent;
    return luminance < 0.5 ? NSColor.whiteColor : NSColor.blackColor;
}

- (NSColor *)labelColorWithInk:(CGFloat)fraction {
    return blendP3([self bgColor], fraction, [self inkColor]) ?: NSColor.secondaryLabelColor;
}

- (NSColor *)colorForLevel:(CGFloat)level {
    const int last = spectrogram_colormap::kLutSize - 1;
    return [self lutColor:_lut[std::max(0, std::min(last, (int)std::lround(level * last)))]];
}

// A LUT entry as a color, in the LUT's color space.
- (NSColor *)lutColor:(uint32_t)c {
    if (_lutIsP3) return JLColorFromARGB(c);
    return [NSColor colorWithSRGBRed:((c >> 16) & 0xFF) / 255.0
                               green:((c >> 8) & 0xFF) / 255.0
                                blue:(c & 0xFF) / 255.0
                               alpha:1.0];
}

- (NSColorSpace *)lutColorSpace {
    return _lutIsP3 ? [NSColorSpace displayP3ColorSpace] : [NSColorSpace sRGBColorSpace];
}

#pragma mark - Layout

- (void)layoutPlot {
    const NSRect b = self.bounds;
    const BOOL tall = b.size.height >= 60.0;
    _drawAxis = _showFreqAxis && tall && b.size.width >= 200.0;
    _drawLegend = _showLegend && tall && b.size.width >= 280.0;

    // Frequency labels are at most four characters ("12k5"); the font is
    // monospaced, so that width fits them all.
    NSDictionary *freqAttrs = @{NSFontAttributeName: labelFont(_freqFontSize, NSFontWeightSemibold)};
    _axisWidth = kAxisGap + std::ceil([@"00k0" sizeWithAttributes:freqAttrs].width);
    [self layoutDbLabelsForHeight:b.size.height];

    const CGFloat right = (_drawAxis ? _axisWidth : 0.0) + (_drawLegend ? _legendWidth : 0.0);
    _plotRect = NSMakeRect(0.0, 0.0,
                           std::max<CGFloat>(0.0, std::floor(b.size.width - right)),
                           std::floor(b.size.height));
    _plotView.frame = _plotRect;
    _overlayView.frame = b;

    const NSInteger wanted = (NSInteger)std::lround(_plotRect.size.height * [self columnsPerPoint]);
    if (wanted != _wantedRows) {
        _wantedRows = wanted;
        _wantedSince = CACurrentMediaTime();
    }

    [self positionTiles];
    [_overlayView setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutPlot];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self layoutPlot];
    if ([self.delegate respondsToSelector:@selector(spectrogramViewDidMoveToWindow:)]) {
        [self.delegate spectrogramViewDidMoveToWindow:self];
    }
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    // Tiles hold device pixels; another scale factor means another density.
    [self clear];
    [self layoutPlot];
}

- (NSInteger)plotRows {
    if (_rows != _wantedRows &&
        (_rows == 0 || CACurrentMediaTime() - _wantedSince >= kResizeSettle)) {
        _rows = _wantedRows;
    }
    return _rows;
}

- (CGFloat)columnsPerPoint {
    const CGFloat scale = [self convertSizeToBacking:NSMakeSize(1.0, 1.0)].width;
    return scale > 0.0 ? scale : 1.0;
}

#pragma mark - Tiles

- (void)appendColumn:(const float *)levels rows:(NSInteger)rows {
    if (rows <= 0) return;

    if (_tiles.empty() || _tiles.back().rows != rows || _tiles.back().count == kTileColumns) {
        Tile tile;
        tile.start = _columns;
        tile.rows = (int)rows;
        tile.px.assign((size_t)kTileColumns * (size_t)rows, 0);
        tile.layer = [CALayer layer];
        tile.layer.anchorPoint = CGPointZero;
        tile.layer.opaque = YES;
        tile.layer.contentsGravity = kCAGravityResize;
        tile.layer.actions = @{ @"position": [NSNull null], @"bounds": [NSNull null],
                                @"contents": [NSNull null], @"onOrderIn": [NSNull null],
                                @"onOrderOut": [NSNull null] };
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [_plotView.layer addSublayer:tile.layer];
        [CATransaction commit];
        _tiles.push_back(std::move(tile));
    }

    Tile &tile = _tiles.back();
    const int last = spectrogram_colormap::kLutSize - 1;
    uint32_t *px = tile.px.data() + tile.count;
    for (NSInteger r = 0; r < rows; ++r) {
        const int idx = (int)(levels[r] * last + 0.5f);
        px[(size_t)r * kTileColumns] = _lut[idx < 0 ? 0 : (idx > last ? last : idx)];
    }
    tile.count++;
    tile.dirty = true;
    _columns++;
}

// Hand the tile's filled columns to its layer as an image.
- (void)uploadTile:(Tile &)tile {
    const size_t w = (size_t)tile.count, h = (size_t)tile.rows;
    const size_t bytes = w * h * sizeof(uint32_t);
    uint32_t *copy = (uint32_t *)malloc(bytes);
    if (!copy) return;
    for (size_t r = 0; r < h; ++r) {
        memcpy(copy + r * w, tile.px.data() + r * kTileColumns, w * sizeof(uint32_t));
    }

    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, copy, bytes, releasePixels);
    CGImageRef image = CGImageCreate(w, h, 8, 32, w * sizeof(uint32_t), _colorSpace,
                                     (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    tile.layer.contents = (__bridge id)image;
    CGImageRelease(image);
}

- (void)flushWithPhase:(CGFloat)phase {
    _phase = phase;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (size_t i = 0; i < _tiles.size(); ++i) {
        Tile &tile = _tiles[i];
        if (tile.dirty) {
            [self uploadTile:tile];
            tile.dirty = false;
        }
        // Only the newest tile is written to again.
        if (i + 1 < _tiles.size() && !tile.px.empty()) std::vector<uint32_t>().swap(tile.px);
    }
    [self positionTiles];
    [CATransaction commit];
}

// The newest column sits at the plot's right edge, less the phase; everything
// else follows from its distance in columns. Tiles that have left the plot are
// dropped.
- (void)positionTiles {
    const CGFloat scale = [self columnsPerPoint];
    const int64_t plotColumns = (int64_t)std::lround(_plotRect.size.width * scale);

    while (!_tiles.empty() && _tiles.front().start + _tiles.front().count <= _columns - plotColumns) {
        [_tiles.front().layer removeFromSuperlayer];
        _tiles.pop_front();
    }
    for (Tile &tile : _tiles) {
        const CGFloat x = ((CGFloat)(plotColumns - (_columns - tile.start)) - _phase) / scale;
        tile.layer.frame = CGRectMake(x, 0.0, (CGFloat)tile.count / scale, _plotRect.size.height);
    }
}

- (void)clear {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (Tile &tile : _tiles) [tile.layer removeFromSuperlayer];
    [CATransaction commit];
    _tiles.clear();
    _columns = 0;
    _phase = 0.0;
}

#pragma mark - Axis geometry

- (CGFloat)fractionForHz:(double)hz {
    return (CGFloat)SpectrogramEngine::fractionForHz(_scale, _minHz, _maxHz, hz);
}

- (double)hzForFraction:(CGFloat)t {
    return SpectrogramEngine::hzForFraction(_scale, _minHz, _maxHz, t);
}

// Frequencies to label, chosen so labels stay at least `gap` points apart.
// Round numbers win: decades first, then 2 and 5, then the rest.
- (std::vector<double>)labelFrequenciesWithGap:(CGFloat)gap {
    struct Candidate { double hz; int rank; };
    std::vector<Candidate> candidates;
    const CGFloat h = _plotRect.size.height;

    if (_scale == SpectrogramEngine::ScaleLinear) {
        const double target = (_maxHz - _minHz) * (gap * 2.5) / h;  // Hz per label slot
        const double p = std::pow(10.0, std::floor(std::log10(target)));
        double step = 10.0 * p;
        for (double m : {1.0, 2.0, 5.0}) {
            if (m * p >= target) { step = m * p; break; }
        }
        for (double f = std::ceil(_minHz / step) * step; f <= _maxHz + 0.5; f += step) {
            candidates.push_back({f, 0});
        }
    } else {
        static const Candidate kMantissas[] = {
            {1, 0}, {2, 1}, {5, 1}, {3, 2}, {4, 3}, {7, 3}, {1.5, 4}, {6, 4}, {8, 4}, {9, 5}
        };
        for (int e = 0; e <= 5; ++e) {
            const double decade = std::pow(10.0, e);
            for (const Candidate &m : kMantissas) {
                const double f = m.hz * decade;
                if (f >= _minHz && f <= _maxHz) candidates.push_back({f, m.rank});
            }
        }
    }
    std::stable_sort(candidates.begin(), candidates.end(),
                     [](const Candidate &a, const Candidate &b) { return a.rank < b.rank; });

    std::vector<double> chosen;
    std::vector<CGFloat> taken;
    for (const Candidate &c : candidates) {
        const CGFloat y = [self fractionForHz:c.hz] * h;
        bool clear = true;
        for (CGFloat t : taken) {
            if (std::fabs(t - y) < gap) { clear = false; break; }
        }
        if (!clear) continue;
        taken.push_back(y);
        chosen.push_back(c.hz);
    }
    return chosen;
}

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

#pragma mark - Overlay drawing

- (void)drawOverlay {
    if (_plotRect.size.width < 1.0 || _plotRect.size.height < 1.0) return;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];

    if (_drawAxis || _gridOpacity > 0) [self drawFrequencyAxisInContext:ctx];
    if (_drawLegend) [self drawLegendInContext:ctx];
    if (_probing) [self drawProbeInContext:ctx];
}

- (void)drawFrequencyAxisInContext:(CGContextRef)ctx {
    NSDictionary *attrs = @{NSFontAttributeName: labelFont(_freqFontSize, NSFontWeightRegular),
                            NSForegroundColorAttributeName: [self labelColorWithInk:kLabelInk]};
    NSDictionary *decadeAttrs = @{NSFontAttributeName: labelFont(_freqFontSize, NSFontWeightSemibold),
                                  NSForegroundColorAttributeName: [self labelColorWithInk:kDecadeInk]};
    const CGFloat labelH = [@"0" sizeWithAttributes:attrs].height;
    const NSRect p = _plotRect;
    const CGFloat maxLabelY = NSMaxY(self.bounds) - labelH;
    NSColor *lineColor = [self gridLineColor];

    CGContextSetLineWidth(ctx, 1.0);
    for (double hz : [self labelFrequenciesWithGap:labelH + 2.0]) {
        const CGFloat y = NSMinY(p) + [self fractionForHz:hz] * p.size.height;
        const CGFloat lineY = std::min(std::floor(y), NSMaxY(p) - 1.0) + 0.5;

        if (_gridOpacity > 0) {
            // Per line: drawing a label sets the context's colors to its own.
            CGContextSetStrokeColorWithColor(ctx, lineColor.CGColor);
            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, NSMinX(p), lineY);
            CGContextAddLineToPoint(ctx, NSMaxX(p), lineY);
            CGContextStrokePath(ctx);
        }
        if (_drawAxis) {
            const CGFloat ty = std::max<CGFloat>(0.0, std::min(y - labelH / 2.0, maxLabelY));
            [compactHz(hz) drawAtPoint:NSMakePoint(NSMaxX(p) + kAxisGap, ty)
                        withAttributes:isDecade(hz) ? decadeAttrs : attrs];
        }
    }
}

// dB levels to label on the color bar for a panel of `height` points, top
// first, and the legend width they need. The top label carries the unit, as
// in the Spectrum Analyzer.
- (void)layoutDbLabelsForHeight:(CGFloat)height {
    NSDictionary *attrs = @{NSFontAttributeName: labelFont(_dbFontSize, NSFontWeightRegular)};
    const CGFloat labelH = [@"0" sizeWithAttributes:attrs].height;
    const CGFloat barH = height - 2.0 * (std::ceil(labelH / 2.0) + 1.0);

    _dbLabels.clear();
    int step = 60;
    for (int s : {10, 20, 30}) {
        if (barH * s / _rangeDb >= labelH + 4.0) { step = s; break; }
    }
    const int floorDb = _topDb - _rangeDb;
    CGFloat widest = 0.0;
    for (int db = (int)std::floor((double)_topDb / step) * step; db >= floorDb; db -= step) {
        NSString *text = _dbLabels.empty() ? [NSString stringWithFormat:@"%d dB", db]
                                           : [NSString stringWithFormat:@"%d", db];
        widest = std::max(widest, [text sizeWithAttributes:attrs].width);
        _dbLabels.emplace_back(db, text);
    }
    _legendWidth = kLegendGap + kBarWidth + kBarLabelGap + std::ceil(widest) + kEdgeGap;
}

// Color bar beside the frequency labels with the dB level each color stands for.
- (void)drawLegendInContext:(CGContextRef)ctx {
    NSDictionary *attrs = @{NSFontAttributeName: labelFont(_dbFontSize, NSFontWeightRegular),
                            NSForegroundColorAttributeName: [self labelColorWithInk:kLabelInk]};
    const CGFloat labelH = [@"0" sizeWithAttributes:attrs].height;
    const CGFloat inset = std::ceil(labelH / 2.0) + 1.0;  // keeps the end labels inside
    const CGFloat left = NSMaxX(_plotRect) + (_drawAxis ? _axisWidth : 0.0) + kLegendGap;
    const NSRect bar = NSMakeRect(left, NSMinY(_plotRect) + inset,
                                  kBarWidth, _plotRect.size.height - 2.0 * inset);
    if (bar.size.height < 20.0) return;

    const int kStops = 33;
    NSMutableArray<NSColor *> *colors = [NSMutableArray arrayWithCapacity:kStops];
    for (int i = 0; i < kStops; ++i) {
        [colors addObject:[self colorForLevel:(CGFloat)i / (kStops - 1)]];
    }
    std::vector<CGFloat> locations(kStops);
    for (int i = 0; i < kStops; ++i) locations[i] = (CGFloat)i / (kStops - 1);
    NSGradient *gradient = [[NSGradient alloc] initWithColors:colors
                                                  atLocations:locations.data()
                                                   colorSpace:[self lutColorSpace]];
    [gradient drawInRect:bar angle:90.0];

    const int floorDb = _topDb - _rangeDb;
    for (const auto &[db, text] : _dbLabels) {
        const CGFloat y = NSMinY(bar) + bar.size.height * (CGFloat)(db - floorDb) / _rangeDb;
        [text drawAtPoint:NSMakePoint(NSMaxX(bar) + kBarLabelGap, y - labelH / 2.0) withAttributes:attrs];
    }
}

#pragma mark - Frequency probe

// Exact readout for the probe; finer than the axis labels.
static NSString *probeHz(double f) {
    if (f >= 1000.0) return [NSString stringWithFormat:@"%.2f kHz", f / 1000.0];
    if (f >= 100.0)  return [NSString stringWithFormat:@"%.0f Hz", f];
    return [NSString stringWithFormat:@"%.1f Hz", f];
}

// Nearest equal-tempered note (A4 = 440 Hz), e.g. "C#3".
static NSString *noteName(double f) {
    static const char *const kNames[] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
    const long note = std::lround(69.0 + 12.0 * std::log2(f / 440.0));
    if (note < 0) return @"";
    return [NSString stringWithFormat:@"%s%ld", kNames[note % 12], note / 12 - 1];
}

// Marker line across the plot at the cursor's frequency, plus a label box
// beside the cursor (flipped to stay inside the view).
- (void)drawProbeInContext:(CGContextRef)ctx {
    const NSRect p = _plotRect;
    CGFloat t = (_probePoint.y - NSMinY(p)) / p.size.height;
    if (t < 0) t = 0; else if (t > 1) t = 1;

    // Marker in the colormap's accent, over a soft line of the panel
    // background so it stays visible on parts of the picture of that color.
    NSColor *accent = [self lutColor:_accentColor];
    NSColor *bg = [self bgColor];
    NSColor *ink = [self inkColor];
    const CGFloat lineY = std::min(std::floor(NSMinY(p) + t * p.size.height), NSMaxY(p) - 1.0) + 0.5;
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, NSMinX(p), lineY);
    CGContextAddLineToPoint(ctx, NSMaxX(p), lineY);
    CGContextSetLineWidth(ctx, 3.0);
    CGContextSetStrokeColorWithColor(ctx, [bg colorWithAlphaComponent:0.55].CGColor);
    CGContextReplacePathWithStrokedPath(ctx);
    CGContextSetFillColorWithColor(ctx, [bg colorWithAlphaComponent:0.55].CGColor);
    CGContextFillPath(ctx);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextSetStrokeColorWithColor(ctx, accent.CGColor);
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, NSMinX(p), lineY);
    CGContextAddLineToPoint(ctx, NSMaxX(p), lineY);
    CGContextStrokePath(ctx);

    // Box as in the Spectrum Analyzer: "702 Hz   F5", the note in the accent.
    const double hz = [self hzForFraction:t];
    NSFont *font = labelFont(_freqFontSize, NSFontWeightMedium);
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
        initWithString:[probeHz(hz) stringByAppendingString:@"   "]
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: ink}];
    [text appendAttributedString:[[NSAttributedString alloc]
        initWithString:noteName(hz)
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: accent}]];

    const NSSize sz = text.size;
    const CGFloat padX = 8.0, padY = 4.0, off = 10.0;
    const CGFloat bw = std::ceil(sz.width) + 2 * padX, bh = std::ceil(sz.height) + 2 * padY;
    const CGRect bounds = self.bounds;

    CGFloat x = _probePoint.x + off, y = _probePoint.y + off;
    if (x + bw > NSMaxX(bounds)) x = _probePoint.x - off - bw;
    if (y + bh > NSMaxY(bounds)) y = _probePoint.y - off - bh;
    x = std::max<CGFloat>(NSMinX(bounds), std::min<CGFloat>(x, NSMaxX(bounds) - bw));
    y = std::max<CGFloat>(NSMinY(bounds), std::min<CGFloat>(y, NSMaxY(bounds) - bh));

    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, bw, bh) xRadius:5 yRadius:5];
    [[bg colorWithAlphaComponent:0.92] setFill];
    [box fill];
    box.lineWidth = 1.0;
    [[accent colorWithAlphaComponent:0.5] setStroke];
    [box stroke];
    [text drawAtPoint:NSMakePoint(x + padX, y + padY)];
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
    [_overlayView setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_probing) return;
    _probePoint = [self convertPoint:event.locationInWindow fromView:nil];
    [_overlayView setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    if (!_probing) return;
    _probing = NO;
    [_overlayView setNeedsDisplay:YES];
}

#pragma mark - Context menu

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    if ([self.delegate respondsToSelector:@selector(spectrogramViewRequestsContextMenu:atPoint:)]) {
        [self.delegate spectrogramViewRequestsContextMenu:self atPoint:pt];
    } else {
        [super rightMouseDown:event];
    }
}

@end
