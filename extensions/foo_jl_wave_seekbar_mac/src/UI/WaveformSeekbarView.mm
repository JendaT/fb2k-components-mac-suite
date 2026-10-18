//
//  WaveformSeekbarView.mm
//  foo_wave_seekbar_mac
//
//  Custom NSView for rendering the waveform seekbar.
//
//  Rendering model: the waveform's layers are cached as greyscale alpha
//  masks per track and pixel size, and coloured into one composite image
//  per theme and style. A frame draws that composite twice under two clip
//  rects (played at playedOpacity, the rest opaque), then the cursor. A
//  theme change, or a change between the Simple styles, recolours the
//  masks; only a new track, size or style family rebuilds them.
//

#import "WaveformSeekbarView.h"
#include "../fb2k_sdk.h"
#include "../Core/WaveformData.h"
#include "../Core/WaveformConfig.h"
#include "../Core/ConfigHelper.h"
#include "../Core/ColumnAggregator.h"
#include "../Core/LayeredShape.h"
#include "../Core/SimpleShape.h"
#include "../Core/ThemeTokens.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace {

// Style Layered: peak envelope fill and edge, then the loudness body
const CGFloat kPeakFillAlpha = 0.26;
const CGFloat kPeakEdgeAlpha = 0.55;
const CGFloat kHalfInset = 2.0;         // pt left free at each half's outer edge

// Styles Simple: two lanes with a gap, peaks reaching almost to the lane edge
const CGFloat kLaneGap = 2.0;
const CGFloat kLaneInset = 1.0;
const float kSimpleCentreLineMix = 0.85f;   // accent towards black
const float kTwoTonePeakMix = 0.5f;
const float kGlowPeakMix[3] = { 0.82f, 0.55f, 0.20f };   // edge, mid, centre

// Cursor time chip
const CGFloat kChipOffset = 4.0;        // from the cursor line and the top edge
const CGFloat kChipPadX = 4.0;
const CGFloat kChipPadY = 1.5;
const CGFloat kChipRadius = 2.0;

// Mask slots. Layered: peak fill, peak edge, body. Simple: peaks, RMS core.
enum MaskIndex { MaskPeakFill = 0, MaskPeakEdge, MaskBody, MaskCount };
enum MaskIndexSimple { MaskSimplePeak = 0, MaskSimpleCore };

bool isSimple(int style) {
    return style != waveform_config::StyleLayered;
}

const theme::RGB kBlack = { 0, 0, 0 };

// Lanes of the Simple styles in a rect `height` high, `unit` per point:
// [0] = L on top, [1] = R below; one lane fills the rect
struct Lanes {
    int count;
    CGFloat bottom[2], center[2];
    CGFloat height, amplitude;
};

Lanes lanesFor(CGFloat height, CGFloat unit, int count) {
    Lanes l;
    l.count = count == 1 ? 1 : 2;
    l.height = l.count == 1 ? height : std::max<CGFloat>(0.0, (height - kLaneGap * unit) / 2.0);
    l.bottom[0] = height - l.height;
    l.bottom[1] = 0.0;
    for (int i = 0; i < l.count; ++i) l.center[i] = l.bottom[i] + l.height / 2.0;
    l.amplitude = std::max<CGFloat>(0.0, l.height / 2.0 - kLaneInset * unit);
    return l;
}

// Area between two signed outlines around a lane centre, one vertex per
// column centre
void addBand(CGMutablePathRef path, const std::vector<float>& top, const std::vector<float>& bottom,
             CGFloat centerY, CGFloat amplitude) {
    const size_t n = top.size();
    if (n == 0) return;
    CGPathMoveToPoint(path, NULL, 0, centerY + top[0] * amplitude);
    for (size_t c = 0; c < n; ++c) CGPathAddLineToPoint(path, NULL, c + 0.5, centerY + top[c] * amplitude);
    CGPathAddLineToPoint(path, NULL, n, centerY + top[n - 1] * amplitude);
    CGPathAddLineToPoint(path, NULL, n, centerY + bottom[n - 1] * amplitude);
    for (size_t c = n; c-- > 0;) CGPathAddLineToPoint(path, NULL, c + 0.5, centerY + bottom[c] * amplitude);
    CGPathAddLineToPoint(path, NULL, 0, centerY + bottom[0] * amplitude);
    CGPathCloseSubpath(path);
}

// How one mask is coloured: flat, or a vertical gradient mirrored around
// each lane's centre (edge, mid, centre, mid, edge)
struct Paint {
    int mask;
    theme::RGB edge, mid, centre;
    CGFloat alpha;
    bool laneGradient;
};

void setFill(CGContextRef ctx, const theme::RGB& c, CGFloat alpha) {
    CGContextSetRGBFillColor(ctx, c.r, c.g, c.b, alpha);
}

void setStroke(CGContextRef ctx, const theme::RGB& c, CGFloat alpha) {
    CGContextSetRGBStrokeColor(ctx, c.r, c.g, c.b, alpha);
}

// m:ss, or h:mm:ss from an hour on
NSString *formatTime(double seconds) {
    const long total = (long)std::max(0.0, std::floor(seconds));
    if (total >= 3600) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", total / 3600, (total / 60) % 60, total % 60];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60];
}

// Greyscale mask: black hides, white shows
CGContextRef createMaskContext(size_t width, size_t height) {
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, width, height, 8, 0, gray, kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!ctx) return NULL;
    CGContextSetGrayFillColor(ctx, 0.0, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    CGContextSetGrayStrokeColor(ctx, 1.0, 1.0);
    return ctx;
}

// Area between the centre line and the heights, one vertex per column
// centre; `dir` +1 grows up, -1 down
void addHalfShape(CGMutablePathRef path, const std::vector<float>& frac, CGFloat centerY,
                  CGFloat amplitude, CGFloat dir) {
    const size_t n = frac.size();
    if (n == 0) return;
    CGPathMoveToPoint(path, NULL, 0, centerY);
    CGPathAddLineToPoint(path, NULL, 0, centerY + dir * frac[0] * amplitude);
    for (size_t c = 0; c < n; ++c) {
        CGPathAddLineToPoint(path, NULL, c + 0.5, centerY + dir * frac[c] * amplitude);
    }
    CGPathAddLineToPoint(path, NULL, n, centerY + dir * frac[n - 1] * amplitude);
    CGPathAddLineToPoint(path, NULL, n, centerY);
    CGPathCloseSubpath(path);
}

// The outline of the heights, broken where they drop under half a pixel so
// silence leaves only the centre line
void addEdge(CGMutablePathRef path, const std::vector<float>& frac, CGFloat centerY,
             CGFloat amplitude, CGFloat dir) {
    bool open = false;
    for (size_t c = 0; c < frac.size(); ++c) {
        const CGFloat h = frac[c] * amplitude;
        if (h < 0.5) { open = false; continue; }
        const CGPoint p = CGPointMake(c + 0.5, centerY + dir * h);
        if (open) CGPathAddLineToPoint(path, NULL, p.x, p.y);
        else CGPathMoveToPoint(path, NULL, p.x, p.y);
        open = true;
    }
}

} // namespace

@interface WaveformSeekbarView () {
    NSTrackingArea *_trackingArea;
    NSDictionary *_placeholderAttributes;
    NSFont *_chipFont;
    theme::Tokens _tokens;

    // Masks per track, pixel size and style family; coloured composite per
    // theme and style
    CGImageRef _masks[MaskCount];
    CGImageRef _composite;
    size_t _maskWidth, _maskHeight;
    bool _maskSimple;
    bool _maskMono;
    int _style;
    bool _mono;
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
    _placeholderAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
    };
    _chipFont = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightBold]
        ?: [NSFont boldSystemFontOfSize:10];

    // Default display settings from config
    [self reloadSettings];

    // Default playback state
    _playbackPosition = 0.0;
    _trackDuration = 0.0;
    _playing = NO;

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
    [self invalidateMasks];
}

- (void)handleSettingsChanged:(NSNotification *)notification {
    [self reloadSettings];
}

- (void)reloadSettings {
    using namespace waveform_config;
    const int64_t style = getConfigInt(kKeyStyle, kDefaultStyle);
    const int newStyle = style >= 0 && style < StyleCount ? (int)style : kDefaultStyle;
    if (isSimple(newStyle) != isSimple(_style)) [self invalidateMasks];
    _style = newStyle;
    _mono = getConfigInt(kKeyChannelMode, kDefaultChannelMode) == ChannelsMono;
    const int64_t opacity = getConfigInt(kKeyPlayedOpacity, kDefaultPlayedOpacity);
    _playedOpacity = std::clamp<int64_t>(opacity, kMinPlayedOpacity, kMaxPlayedOpacity) / 100.0;
    _showCursorTime = getConfigBool(kKeyCursorTime, kDefaultCursorTime);
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

- (BOOL)isDarkAppearance {
    NSAppearanceName name = [self.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [name isEqualToString:NSAppearanceNameDarkAqua];
}

- (void)updateColorsForAppearance {
    using namespace waveform_config;

    const BOOL dark = [self isDarkAppearance];
    const uint32_t waveARGB = static_cast<uint32_t>(dark
        ? getConfigInt(kKeyWaveColorDark, kDefaultWaveColorDark)
        : getConfigInt(kKeyWaveColorLight, kDefaultWaveColorLight));
    const uint32_t bgARGB = static_cast<uint32_t>(dark
        ? getConfigInt(kKeyBgColorDark, kDefaultBgColorDark)
        : getConfigInt(kKeyBgColorLight, kDefaultBgColorLight));

    auto color = [](uint32_t argb) {
        return [NSColor colorWithSRGBRed:((argb >> 16) & 0xFF) / 255.0
                                   green:((argb >> 8) & 0xFF) / 255.0
                                    blue:(argb & 0xFF) / 255.0
                                   alpha:((argb >> 24) & 0xFF) / 255.0];
    };
    _waveformColor = color(waveARGB);
    _backgroundColor = color(bgARGB);

    // The Simple styles draw on black. Over glass (or a see-through
    // colour) the guides are derived against the appearance instead.
    theme::RGB background = theme::RGB::fromARGB(bgARGB);
    if (isSimple(_style)) {
        background = kBlack;
    } else if (_glassBackground || ((bgARGB >> 24) & 0xFF) < 128) {
        background = dark ? kBlack : theme::RGB{ 1, 1, 1 };
    }
    _tokens = theme::deriveTokens(theme::RGB::fromARGB(waveARGB), background);

    [self invalidateComposite];
}

#pragma mark - Caches

- (void)invalidateComposite {
    CGImageRelease(_composite);
    _composite = NULL;
}

- (void)invalidateMasks {
    for (auto& mask : _masks) {
        CGImageRelease(mask);
        mask = NULL;
    }
    _maskWidth = _maskHeight = 0;
    [self invalidateComposite];
}

- (void)setWaveformData:(const WaveformData *)waveformData {
    _waveformData = waveformData;
    [self invalidateMasks];
}

- (BOOL)buildMasksWidth:(size_t)width height:(size_t)height {
    [self invalidateMasks];
    analysis::Columns cols = analysis::aggregateColumns(*self.waveformData, width);
    if (cols.count != width) return NO;
    if (_mono) cols = analysis::mixdown(cols);
    const CGFloat scale = (CGFloat)height / std::max<CGFloat>(1.0, self.bounds.size.height);

    const BOOL built = isSimple(_style)
        ? [self buildSimpleMasks:cols width:width height:height scale:scale]
        : [self buildLayeredMasks:cols width:width height:height scale:scale];
    if (!built) {
        [self invalidateMasks];
        return NO;
    }
    _maskWidth = width;
    _maskHeight = height;
    _maskSimple = isSimple(_style);
    _maskMono = _mono;
    return YES;
}

// Layered: L up, R down on one dBFS axis; peak envelope (fill and edge)
// around the short-term loudness body
- (BOOL)buildLayeredMasks:(const analysis::Columns&)cols width:(size_t)width height:(size_t)height
                    scale:(CGFloat)scale {
    const layered::Shape shape = layered::shapeFor(cols);
    const CGFloat centerY = height / 2.0;
    const CGFloat amplitude = std::max<CGFloat>(0.0, height / 2.0 - kHalfInset * scale);
    const CGFloat dirs[2] = { 1.0, -1.0 };

    for (int m = 0; m < MaskCount; ++m) {
        CGContextRef ctx = createMaskContext(width, height);
        if (!ctx) return NO;
        CGMutablePathRef path = CGPathCreateMutable();
        for (int half = 0; half < 2; ++half) {
            switch (m) {
                case MaskPeakFill: addHalfShape(path, shape.peak[half], centerY, amplitude, dirs[half]); break;
                case MaskPeakEdge: addEdge(path, shape.peak[half], centerY, amplitude, dirs[half]); break;
                case MaskBody:     addHalfShape(path, shape.body[half], centerY, amplitude, dirs[half]); break;
            }
        }
        CGContextAddPath(ctx, path);
        if (m == MaskPeakEdge) {
            CGContextSetLineWidth(ctx, scale);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextStrokePath(ctx);
        } else {
            CGContextFillPath(ctx);
        }
        CGPathRelease(path);
        _masks[m] = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        if (!_masks[m]) return NO;
    }
    return YES;
}

// Simple: L and R in their own lanes, linear; sample min/max around an RMS core
- (BOOL)buildSimpleMasks:(const analysis::Columns&)cols width:(size_t)width height:(size_t)height
                   scale:(CGFloat)scale {
    const simple::Shape shape = simple::shapeFor(cols, _mono ? 1 : 2);
    const Lanes lanes = lanesFor(height, scale, shape.lanes);

    for (int m : { (int)MaskSimplePeak, (int)MaskSimpleCore }) {
        CGContextRef ctx = createMaskContext(width, height);
        if (!ctx) return NO;
        CGMutablePathRef path = CGPathCreateMutable();
        for (int l = 0; l < shape.lanes; ++l) {
            const simple::Lane& lane = shape.lane[l];
            if (m == MaskSimplePeak) addBand(path, lane.top, lane.bottom, lanes.center[l], lanes.amplitude);
            else addBand(path, lane.coreTop, lane.coreBottom, lanes.center[l], lanes.amplitude);
        }
        CGContextAddPath(ctx, path);
        CGContextFillPath(ctx);
        CGPathRelease(path);
        _masks[m] = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        if (!_masks[m]) return NO;
    }
    return YES;
}

// What each style paints through which mask
- (std::vector<Paint>)paints {
    using namespace waveform_config;
    const theme::Tokens& t = _tokens;
    auto flat = [](int mask, const theme::RGB& c, CGFloat alpha) {
        return Paint{ mask, c, c, c, alpha, false };
    };
    auto lanes = [](int mask, const theme::RGB& edge, const theme::RGB& mid, const theme::RGB& centre) {
        return Paint{ mask, edge, mid, centre, 1.0, true };
    };
    switch (_style) {
        case StyleTwoTone:
            return { flat(MaskSimplePeak, theme::mix(t.accent, kBlack, kTwoTonePeakMix), 1.0),
                     flat(MaskSimpleCore, t.accent, 1.0) };
        case StyleGlow:
            return { lanes(MaskSimplePeak, theme::mix(t.accent, kBlack, kGlowPeakMix[0]),
                                           theme::mix(t.accent, kBlack, kGlowPeakMix[1]),
                                           theme::mix(t.accent, kBlack, kGlowPeakMix[2])),
                     lanes(MaskSimpleCore, t.accent, t.accent, t.hot) };
        case StyleHeat:
            return { lanes(MaskSimplePeak, t.hot, t.accent, t.deep) };
        default:
            return { flat(MaskPeakFill, t.accent, kPeakFillAlpha),
                     flat(MaskPeakEdge, t.accent, kPeakEdgeAlpha),
                     flat(MaskBody, t.accent, 1.0) };
    }
}

- (BOOL)buildComposite {
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, _maskWidth, _maskHeight, 8, 0, srgb,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(srgb);
    if (!ctx) return NO;

    const CGRect full = CGRectMake(0, 0, _maskWidth, _maskHeight);
    const CGFloat scale = (CGFloat)_maskHeight / std::max<CGFloat>(1.0, self.bounds.size.height);
    const Lanes lanes = lanesFor(_maskHeight, scale, _maskMono ? 1 : 2);
    CGColorSpaceRef gradientSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    for (const Paint& p : [self paints]) {
        if (!_masks[p.mask]) continue;
        CGContextSaveGState(ctx);
        CGContextClipToMask(ctx, full, _masks[p.mask]);
        if (!p.laneGradient) {
            setFill(ctx, p.centre, p.alpha);
            CGContextFillRect(ctx, full);
        } else {
            const theme::RGB stops[5] = { p.edge, p.mid, p.centre, p.mid, p.edge };
            CGFloat components[20];
            for (int i = 0; i < 5; ++i) {
                components[i * 4] = stops[i].r;
                components[i * 4 + 1] = stops[i].g;
                components[i * 4 + 2] = stops[i].b;
                components[i * 4 + 3] = p.alpha;
            }
            const CGFloat locations[5] = { 0.0, 0.25, 0.5, 0.75, 1.0 };
            CGGradientRef gradient = CGGradientCreateWithColorComponents(gradientSpace, components, locations, 5);
            for (int l = 0; gradient && l < lanes.count; ++l) {
                CGContextSaveGState(ctx);
                CGContextClipToRect(ctx, CGRectMake(0, lanes.bottom[l], _maskWidth, lanes.height));
                CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, lanes.bottom[l]),
                                            CGPointMake(0, lanes.bottom[l] + lanes.height), 0);
                CGContextRestoreGState(ctx);
            }
            CGGradientRelease(gradient);
        }
        CGContextRestoreGState(ctx);
    }
    CGColorSpaceRelease(gradientSpace);
    _composite = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return _composite != NULL;
}

#pragma mark - Drawing

- (BOOL)isOpaque {
    if (self.glassBackground) return NO;
    return self.backgroundColor.alphaComponent >= 1.0;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    if (!context) return;

    @try {
        const CGRect bounds = self.bounds;

        // In glass mode skip an opaque colour so the blur shows through, but
        // let a translucent colour act as a tint over the blur. The Simple
        // styles draw on black.
        const CGFloat bgAlpha = self.backgroundColor.alphaComponent;
        if (!self.glassBackground) {
            if (isSimple(_style)) setFill(context, kBlack, 1.0);
            else CGContextSetFillColorWithColor(context, self.backgroundColor.CGColor);
            CGContextFillRect(context, bounds);
        } else if (bgAlpha > 0.0 && bgAlpha < 1.0) {
            CGContextSetFillColorWithColor(context, self.backgroundColor.CGColor);
            CGContextFillRect(context, bounds);
        }

        const bool hasWaveform = self.waveformData && self.waveformData->isValid();
        [self drawGuidesInContext:context rect:bounds full:hasWaveform];

        if (hasWaveform) {
            [self drawWaveformInContext:context rect:bounds];
        } else {
            [self drawPlaceholderInContext:context rect:bounds];
        }

        [self drawCursorInContext:context rect:bounds];
    } @catch (NSException *e) {
        // An exception out of drawRect: takes foobar2000 down
        FB2K_console_formatter() << "[WaveSeek] Drawing failed: " << (e.reason ? e.reason.UTF8String : "?");
    }
}

- (CGFloat)backingScale {
    const CGFloat scale = self.window.backingScaleFactor;
    return scale > 0 ? scale : 2.0;
}

// Layered: centre line, and the -12 / -24 dB gridlines in each half.
// Simple: each lane's centre line.
- (void)drawGuidesInContext:(CGContextRef)context rect:(CGRect)rect full:(bool)full {
    const CGFloat scale = [self backingScale];
    auto snap = [&](CGFloat y) { return (std::floor(y * scale) + 0.5) / scale; };

    if (isSimple(_style)) {
        const Lanes lanes = lanesFor(rect.size.height, 1.0, _mono ? 1 : 2);
        CGContextSaveGState(context);
        CGContextSetLineWidth(context, 1.0);
        setStroke(context, theme::mix(_tokens.accent, kBlack, kSimpleCentreLineMix), 1.0);
        for (int l = 0; l < lanes.count; ++l) {
            const CGFloat y = snap(rect.origin.y + lanes.center[l]);
            CGContextMoveToPoint(context, rect.origin.x, y);
            CGContextAddLineToPoint(context, CGRectGetMaxX(rect), y);
        }
        CGContextStrokePath(context);
        CGContextRestoreGState(context);
        return;
    }

    const CGFloat centerY = CGRectGetMidY(rect);
    const CGFloat amplitude = std::max<CGFloat>(0.0, rect.size.height / 2.0 - kHalfInset);

    CGContextSaveGState(context);
    CGContextSetLineWidth(context, 1.0);
    if (full) {
        setStroke(context, _tokens.grid, 1.0);
        for (float db : layered::kGridDb) {
            const CGFloat h = layered::fraction(db) * amplitude;
            for (CGFloat y : { centerY + h, centerY - h }) {
                CGContextMoveToPoint(context, rect.origin.x, snap(y));
                CGContextAddLineToPoint(context, CGRectGetMaxX(rect), snap(y));
            }
        }
        CGContextStrokePath(context);
    }
    setStroke(context, _tokens.centre, 1.0);
    CGContextMoveToPoint(context, rect.origin.x, snap(centerY));
    CGContextAddLineToPoint(context, CGRectGetMaxX(rect), snap(centerY));
    CGContextStrokePath(context);
    CGContextRestoreGState(context);
}

- (void)drawWaveformInContext:(CGContextRef)context rect:(CGRect)rect {
    const CGSize pixelSize = [self convertSizeToBacking:rect.size];
    const size_t pixelW = (size_t)std::lround(pixelSize.width);
    const size_t pixelH = (size_t)std::lround(pixelSize.height);
    if (pixelW == 0 || pixelH == 0) return;

    if (pixelW != _maskWidth || pixelH != _maskHeight || !_masks[0] || _maskSimple != isSimple(_style) || _maskMono != _mono) {
        if (![self buildMasksWidth:pixelW height:pixelH]) return;
    }
    if (!_composite && ![self buildComposite]) return;

    // Same image twice: played at playedOpacity, the rest opaque
    const CGFloat split = rect.origin.x + rect.size.width * std::clamp(self.playbackPosition, 0.0, 1.0);
    CGContextSaveGState(context);
    CGContextClipToRect(context, CGRectMake(rect.origin.x, rect.origin.y, split - rect.origin.x, rect.size.height));
    CGContextSetAlpha(context, self.playedOpacity);
    CGContextDrawImage(context, rect, _composite);
    CGContextRestoreGState(context);

    CGContextSaveGState(context);
    CGContextClipToRect(context, CGRectMake(split, rect.origin.y, CGRectGetMaxX(rect) - split, rect.size.height));
    CGContextDrawImage(context, rect, _composite);
    CGContextRestoreGState(context);
}

- (void)drawPlaceholderInContext:(CGContextRef)context rect:(CGRect)rect {
    NSString *text = self.analyzing ? @"Analyzing..." : @"No waveform";
    const NSSize size = [text sizeWithAttributes:_placeholderAttributes];
    [text drawAtPoint:NSMakePoint(CGRectGetMidX(rect) - size.width / 2, CGRectGetMidY(rect) - size.height / 2)
       withAttributes:_placeholderAttributes];
}

// 1 pt line, and the time in a chip beside it at the top
- (void)drawCursorInContext:(CGContextRef)context rect:(CGRect)rect {
    if (self.trackDuration <= 0.0 || (self.playbackPosition <= 0.0 && !self.playing)) return;

    const CGFloat scale = [self backingScale];
    const CGFloat x = (std::floor((rect.origin.x + rect.size.width * self.playbackPosition) * scale) + 0.5) / scale;

    CGContextSaveGState(context);
    setStroke(context, _tokens.cursor, 1.0);
    CGContextSetLineWidth(context, 1.0);
    CGContextMoveToPoint(context, x, rect.origin.y);
    CGContextAddLineToPoint(context, x, CGRectGetMaxY(rect));
    CGContextStrokePath(context);
    CGContextRestoreGState(context);

    if (!self.showCursorTime) return;
    NSDictionary *attrs = @{
        NSFontAttributeName: _chipFont,
        NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:_tokens.cursorText.r
                                                            green:_tokens.cursorText.g
                                                             blue:_tokens.cursorText.b
                                                            alpha:1.0]
    };
    NSString *time = formatTime(self.playbackPosition * self.trackDuration);
    const NSSize textSize = [time sizeWithAttributes:attrs];
    const CGFloat chipW = std::ceil(textSize.width + 2 * kChipPadX);
    const CGFloat chipH = std::ceil(textSize.height + 2 * kChipPadY);
    if (chipH + 2 * kChipOffset > rect.size.height) return;

    CGFloat chipX = x + kChipOffset;
    if (chipX + chipW > CGRectGetMaxX(rect)) chipX = x - kChipOffset - chipW;   // flip near the right edge
    const CGRect chip = CGRectMake(std::round(chipX), CGRectGetMaxY(rect) - kChipOffset - chipH, chipW, chipH);

    CGContextSaveGState(context);
    setFill(context, _tokens.cursor, 1.0);
    CGPathRef shape = CGPathCreateWithRoundedRect(chip, kChipRadius, kChipRadius, NULL);
    CGContextAddPath(context, shape);
    CGContextFillPath(context);
    CGPathRelease(shape);
    CGContextRestoreGState(context);

    [time drawAtPoint:NSMakePoint(chip.origin.x + kChipPadX, chip.origin.y + kChipPadY) withAttributes:attrs];
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
    if ([self.delegate respondsToSelector:@selector(waveformSeekbarViewRequestsContextMenu:atPoint:)]) {
        [self.delegate waveformSeekbarViewRequestsContextMenu:self atPoint:location];
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
