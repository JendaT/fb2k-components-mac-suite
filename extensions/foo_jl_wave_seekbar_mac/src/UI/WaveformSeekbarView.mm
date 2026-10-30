//
//  WaveformSeekbarView.mm
//  foo_wave_seekbar_mac
//
//  Custom NSView for rendering the waveform seekbar.
//
//  Rendering model: the waveform's layers are cached as greyscale alpha
//  masks per track and pixel size, and coloured into one composite image
//  per theme and style. A frame draws that composite, dims the played part
//  with an overlay of the background shaped by the cursor effect, then the
//  cursor and overlays. A
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
#include "../Core/OverlayText.h"
#include "../Core/WaveformColorMap.h"
#include "../Core/WaveformGeometry.h"
#include "../Core/GradientBandTable.h"
#include "../Core/ThemeTokens.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace analysis = waveseek::analysis;
namespace layered = waveseek::layered;
namespace overlay = waveseek::overlay;
namespace simple = waveseek::simple;
namespace theme = waveseek::theme;

namespace {

// Style Layered: peak envelope fill and edge, then the loudness body tinted
// by the passage's spectral balance (theme::tintColor)
const CGFloat kPeakFillAlpha = 0.26;
const CGFloat kPeakEdgeAlpha = 0.55;
const CGFloat kHalfInset = 2.0;         // pt left free at each lane's outer edges

// Styles Layered and Simple: two lanes with a gap; Simple's peaks reach
// almost to the lane edge
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

// Mask slots. Layered: peak fill, peak edge, body. Simple: peaks, RMS
// core. Classic: symmetric peaks.
enum MaskIndex { MaskPeakFill = 0, MaskPeakEdge, MaskBody, MaskCount };
enum MaskIndexSimple { MaskSimplePeak = 0, MaskSimpleCore };

// Styles that share geometry share masks
enum Family { FamilyLayered, FamilySimple, FamilyClassic };

Family familyOf(int style) {
    using namespace waveform_config;
    switch (style) {
        case StyleTwoTone: case StyleGlow: case StyleHeat: return FamilySimple;
        case StyleHeatMap: case StyleRainbow: case StyleSolid: return FamilyClassic;
        default: return FamilyLayered;
    }
}

// Simple and Classic draw L and R in lanes, on a linear scale
bool usesLanes(int style) {
    return familyOf(style) != FamilyLayered;
}

// Classic colours, as the original Heat map and Rainbow styles drew them
// (WaveformColorMap.h): blue (quiet) -> cyan -> green -> yellow -> red (loud)
theme::RGB heatMapColor(float amplitude) {
    const waveseek::Rgb c = waveseek::heatMapColor(amplitude);
    return { (float)c.r, (float)c.g, (float)c.b };
}

// Classic styles draw as the original did: 2048 one-point strokes at their
// bucket positions (the antialiasing gives them their fine texture), halves
// without a gap, peaks 4 pt from the edges (WaveformGeometry.h). Solid's
// gradient bands step down to 40 % at full amplitude (bandAlpha).
const size_t kClassicBuckets = 2048;
const CGFloat kClassicPadding = waveseek::kWaveformPadding;

// Rainbow: fully saturated hue by position across the track, 0..1
theme::RGB rainbowColor(float position) {
    const waveseek::Rgb c = waveseek::rainbowColor(position);
    return { (float)c.r, (float)c.g, (float)c.b };
}

const theme::RGB kBlack = { 0, 0, 0 };

// Lanes in a rect `height` high, `unit` per point: [0] = L on top, [1] = R
// below; one lane fills the rect. Layered: a gap between them, peaks 2 pt
// from the edges. Simple: a gap, peaks almost to the edge. Classic: no gap,
// 4 pt padding.
struct Lanes {
    int count;
    CGFloat bottom[2], center[2];
    CGFloat height, amplitude;
};

Lanes lanesFor(CGFloat height, CGFloat unit, int count, Family family = FamilySimple) {
    Lanes l;
    l.count = count == 1 ? 1 : 2;
    const CGFloat gap = family == FamilyClassic ? 0.0 : kLaneGap;
    const CGFloat inset = family == FamilyLayered ? kHalfInset
                        : family == FamilyClassic ? kClassicPadding : kLaneInset;
    l.height = l.count == 1 ? height : std::max<CGFloat>(0.0, (height - gap * unit) / 2.0);
    l.bottom[0] = height - l.height;
    l.bottom[1] = 0.0;
    for (int i = 0; i < l.count; ++i) l.center[i] = l.bottom[i] + l.height / 2.0;
    l.amplitude = std::max<CGFloat>(0.0, l.height / 2.0 - inset * unit);
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

NSString *str(const std::string& s) {
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

NSColor *srgb(uint32_t rgb, CGFloat alpha = 1.0) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0 alpha:alpha];
}

// Overlays keep their own dark palette in every theme
const uint32_t kOverlayBackground = 0x13110C;
const CGFloat kOverlayBackgroundAlpha = 0.95;
const uint32_t kOverlayBorder = 0x3A3326;
const uint32_t kOverlayValue = 0xF2E9D6;
const uint32_t kOverlayLabel = 0x9A907D;
const uint32_t kOverlayAlert = 0xF0603F;     // TP above 0, clips
const uint32_t kBandColors[3] = { 0xC7772A, 0xD9C26A, 0xA8D4F2 };   // Lo, Mid, Hi

// Hover readout layout, points from the box's top
const CGFloat kReadoutPadX = 10.0;
const CGFloat kReadoutHeaderY = 7.0;
const CGFloat kReadoutRowsY = 27.0;
const CGFloat kReadoutRowStep = 14.0;
const CGFloat kReadoutBarY = 86.0;
const CGFloat kReadoutBarHeight = 4.0;
const CGFloat kReadoutBandsY = 94.0;
const CGFloat kReadoutHeight = 111.0;
const CGFloat kReadoutCompactHeight = 86.0;  // without the Lo / Mid / Hi section
const CGFloat kReadoutRadius = 4.0;

// Scales: time ruler under the waveform, level gutter on its right. Each
// gives way when the view is too small to keep a usable waveform.
const CGFloat kRulerHeight = 22.0;
const CGFloat kRulerMajorTick = 8.0;
const CGFloat kRulerMinorTick = 4.0;
const CGFloat kRulerLabelGap = 3.0;
const CGFloat kRulerLabelTop = 6.0;
const CGFloat kGutterWidth = 48.0;
const CGFloat kGutterLabelX = 6.0;
const CGFloat kGutterChannelX = 4.0;     // L / R, from the gutter's right edge
const CGFloat kMinWaveformHeight = 40.0;
const CGFloat kWaveformMargin = 8.0;     // above and below the waveform
const CGFloat kMinWaveformWidth = 200.0;
const uint32_t kScaleBorder = 0x2C271D;
const uint32_t kScaleLabel = 0x8A8170;

// Text-dependent sizes above are for 10 pt text and scale with the
// configured size
#define TS(v) ((v) * _textScale)

// Loudness summary badge and clip markers
const CGFloat kBadgeInset = 6.0;
const CGFloat kBadgePadX = 6.0;
const CGFloat kBadgePadY = 3.0;
const CGFloat kBadgeRadius = 3.0;
const CGFloat kClipMarkerWidth = 2.0;
const CGFloat kClipMarkerHeight = 5.0;

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
// silence leaves only the centre line, and where they sit at full scale so a
// track limited to 0 dBFS doesn't draw a flat line along the top
const float kEdgeCeiling = 0.995f;   // within ~0.2 dB of 0 dBFS on the -36 dB axis

// Stroked kEdgeChunk columns at a time: one path with a vertex per pixel
// column takes CoreGraphics 0.1-0.35 s to stroke, on the main thread. Each
// run starts where the last one ended; round caps close the joins.
const size_t kEdgeChunk = 64;

void strokeEdge(CGContextRef ctx, const std::vector<float>& frac, CGFloat centerY,
                CGFloat amplitude, CGFloat dir) {
    size_t points = 0;
    auto finishRun = [&] {
        if (points > 1) CGContextStrokePath(ctx);
        else CGContextBeginPath(ctx);
        points = 0;
    };
    for (size_t c = 0; c < frac.size(); ++c) {
        const CGFloat h = frac[c] * amplitude;
        if (h < 0.5 || frac[c] >= kEdgeCeiling) { finishRun(); continue; }
        const CGPoint p = CGPointMake(c + 0.5, centerY + dir * h);
        if (points == 0) CGContextMoveToPoint(ctx, p.x, p.y);
        else CGContextAddLineToPoint(ctx, p.x, p.y);
        if (++points == kEdgeChunk) {
            CGContextStrokePath(ctx);
            CGContextMoveToPoint(ctx, p.x, p.y);
            points = 1;
        }
    }
    finishRun();
}

} // namespace

@interface WaveformSeekbarView () {
    NSTrackingArea *_trackingArea;
    CGColorSpaceRef _deviceRGBColorSpace;       // Cached for the cursor effects' gradients
    NSFont *_overlayFont;
    NSFont *_overlayBoldFont;
    CGFloat _textScale;          // overlay text size / 10 pt

    // Mouse over the view, for the readout and the summary badge
    BOOL _hovering;
    CGFloat _hoverX;
    BOOL _seeking;               // a click on the waveform, until the mouse is up
    BOOL _showReadout;
    int _readoutPosition;
    float _tintStrength;
    int _summaryMode;
    BOOL _showClipMarkers;
    CGFloat _clipMarkerOpacity;
    BOOL _showTimeRuler;
    BOOL _showLevelScale;

    // Per-column readout values at the masks' pixel width
    analysis::Columns _readout;
    NSDictionary *_placeholderAttributes;
    NSFont *_chipFont;
    theme::Tokens _tokens;

    // Masks per track, pixel size and style family; coloured composite per
    // theme and style
    CGImageRef _masks[MaskCount];
    CGImageRef _composite;
    size_t _maskWidth, _maskHeight;
    Family _maskFamily;
    bool _maskMono;
    std::vector<float> _lanePeak[2];   // Classic: peak per column and lane (or half in Split), for the colours
    bool _classicSplit;                // Classic: L up, R down in one lane
    int _laneCount;
    int _gradientBands;                // Classic Solid
    std::vector<float> _bodyTint;      // Layered: tint position per column
    int _style;
    bool _mono;
    bool _split;                       // L up, R down in one lane
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
    _deviceRGBColorSpace = CGColorSpaceCreateDeviceRGB();
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
    if (_deviceRGBColorSpace) CGColorSpaceRelease(_deviceRGBColorSpace);
}

- (void)handleSettingsChanged:(NSNotification *)notification {
    [self reloadSettings];
}

- (void)reloadSettings {
    using namespace waveform_config;
    const int64_t style = getConfigInt(kKeyWaveformStyle, kDefaultStyle);
    const int newStyle = style >= 0 && style < StyleCount ? (int)style : kDefaultStyle;
    // Classic styles mix mono differently from each other
    if (familyOf(newStyle) != familyOf(_style) || (familyOf(newStyle) == FamilyClassic && newStyle != _style)) {
        [self invalidateMasks];
    }
    _style = newStyle;
    const int64_t channels = getConfigInt(kKeyDisplayMode, kDefaultChannelMode);
    _mono = channels == ChannelsMono;
    const bool split = channels == ChannelsSplit;
    if (split != _split) [self invalidateMasks];
    _split = split;
    _shadePlayedPortion = getConfigBool(kKeyShadePlayedPortion, kDefaultShadePlayedPortion);
    _playedDimming = std::clamp<int64_t>(getConfigInt(kKeyPlayedDimming, kDefaultPlayedDimming), 0, 100) / 100.0;
    const int64_t effect = getConfigInt(kKeyCursorEffect, kDefaultCursorEffect);
    _cursorEffect = (WaveformCursorEffect)(effect >= 0 && effect < CursorEffectCount ? effect : kDefaultCursorEffect);
    _bpmSync = getConfigBool(kKeyBpmSync, kDefaultBpmSync);
    _showCursorTime = getConfigBool(kKeyCursorTime, kDefaultCursorTime);
    _gradientBands = (int)getConfigInt(kKeyGradientBands, kDefaultGradientBands);
    if (std::find(std::begin(waveseek::kGradientBandValues), std::end(waveseek::kGradientBandValues), _gradientBands)
        == std::end(waveseek::kGradientBandValues)) {
        _gradientBands = kDefaultGradientBands;
    }
    _tintStrength = kBodyTintStrength[std::clamp<int64_t>(getConfigInt(kKeyBodyTint, kDefaultBodyTint),
                                                          BodyTintOff, BodyTintStrong)];
    _showReadout = getConfigBool(kKeyHoverReadout, kDefaultHoverReadout);
    _readoutPosition = (int)std::clamp<int64_t>(getConfigInt(kKeyReadoutPosition, kDefaultReadoutPosition),
                                                ReadoutFollowsMouse, ReadoutBottomRight);
    _summaryMode = (int)std::clamp<int64_t>(getConfigInt(kKeySummaryMode, kDefaultSummaryMode), SummaryOff, SummaryAlways);
    _showClipMarkers = getConfigBool(kKeyClipMarkers, kDefaultClipMarkers);
    _clipMarkerOpacity = std::clamp<int64_t>(getConfigInt(kKeyClipMarkerOpacity, kDefaultClipMarkerOpacity),
                                             kMinClipMarkerOpacity, kMaxClipMarkerOpacity) / 100.0;

    // Overlay and scale text
    int64_t textSize = getConfigInt(kKeyTextSize, kDefaultTextSize);
    if (std::find(std::begin(kTextSizes), std::end(kTextSizes), textSize) == std::end(kTextSizes)) {
        textSize = kDefaultTextSize;
    }
    _textScale = textSize / 10.0;
    _overlayFont = [NSFont monospacedSystemFontOfSize:textSize weight:NSFontWeightRegular]
        ?: [NSFont systemFontOfSize:textSize];
    _overlayBoldFont = [NSFont monospacedSystemFontOfSize:textSize weight:NSFontWeightSemibold]
        ?: [NSFont boldSystemFontOfSize:textSize];
    _chipFont = [NSFont monospacedSystemFontOfSize:textSize weight:NSFontWeightBold]
        ?: [NSFont boldSystemFontOfSize:textSize];
    _showTimeRuler = getConfigBool(kKeyTimeRuler, kDefaultTimeRuler);
    _showLevelScale = getConfigBool(kKeyLevelScale, kDefaultLevelScale);
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
        options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInActiveApp)
        owner:self
        userInfo:nil];
    [self addTrackingArea:_trackingArea];

    // The view can move or shrink away from the mouse without an exit event
    if (_hovering && self.window) {
        const NSPoint mouse = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
        if (!NSPointInRect(mouse, self.bounds)) _hovering = NO;
    }
}

// Hidden or moved while the mouse was over it: no exit event either
- (void)viewDidHide {
    [super viewDidHide];
    _hovering = NO;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    _hovering = NO;
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

// The Simple styles draw on black, except over glass
- (BOOL)drawsOnBlack {
    return familyOf(_style) == FamilySimple && !_glassBackground;
}

- (void)updateColorsForAppearance {
    using namespace waveform_config;

    const BOOL dark = [self isDarkAppearance];
    // On black, the Simple styles take the dark-mode wave colour in light
    // mode too
    const BOOL onBlack = [self drawsOnBlack];
    const uint32_t waveARGB = static_cast<uint32_t>((dark || onBlack)
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

    // Over glass (or a see-through colour) the guides are derived against
    // the appearance instead.
    theme::RGB background = theme::RGB::fromARGB(bgARGB);
    if (onBlack) {
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
    _readout = analysis::Columns();
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
    _readout = cols;
    const CGFloat scale = [self backingScale];
    if (familyOf(_style) == FamilyClassic) {
        // The original styles mix mono themselves
        if (![self buildClassicMasks:cols width:width height:height scale:scale]) {
            [self invalidateMasks];
            return NO;
        }
        _maskWidth = width;
        _maskHeight = height;
        _maskFamily = FamilyClassic;
        _maskMono = _mono;
        return YES;
    }
    if (_mono) cols = analysis::mixdown(cols);

    const BOOL built = usesLanes(_style)
        ? [self buildSimpleMasks:cols width:width height:height scale:scale]
        : [self buildLayeredMasks:cols width:width height:height scale:scale];
    if (!built) {
        [self invalidateMasks];
        return NO;
    }
    _maskWidth = width;
    _maskHeight = height;
    _maskFamily = familyOf(_style);
    _maskMono = _mono;
    return YES;
}

// Layered: each channel mirrored in its lane on a dBFS axis, or in Split L
// up and R down around one centre line; peak envelope (fill and edge) around
// the short-term loudness body
- (BOOL)buildLayeredMasks:(const analysis::Columns&)cols width:(size_t)width height:(size_t)height
                    scale:(CGFloat)scale {
    const layered::Shape shape = layered::shapeFor(cols);
    _bodyTint = layered::tintPositions(cols);
    const Lanes lanes = lanesFor(height, scale, _split ? 1 : shape.lanes, FamilyLayered);
    _laneCount = lanes.count;
    const CGFloat dirs[2] = { 1.0, -1.0 };
    // Channel drawn in a lane's upper (0) and lower (1) half
    auto channelOf = [&](int lane, int half) { return _split ? std::min(half, shape.lanes - 1) : lane; };

    for (int m = 0; m < MaskCount; ++m) {
        CGContextRef ctx = createMaskContext(width, height);
        if (!ctx) return NO;
        if (m == MaskPeakEdge) {
            CGContextSetLineWidth(ctx, scale);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            CGContextSetLineCap(ctx, kCGLineCapRound);
            for (int l = 0; l < lanes.count; ++l) {
                for (int half = 0; half < 2; ++half) {
                    strokeEdge(ctx, shape.peak[channelOf(l, half)], lanes.center[l], lanes.amplitude, dirs[half]);
                }
            }
        } else {
            CGMutablePathRef path = CGPathCreateMutable();
            for (int l = 0; l < lanes.count; ++l) {
                for (int half = 0; half < 2; ++half) {
                    const int ch = channelOf(l, half);
                    const std::vector<float>& frac = m == MaskPeakFill ? shape.peak[ch] : shape.body[ch];
                    addHalfShape(path, frac, lanes.center[l], lanes.amplitude, dirs[half]);
                }
            }
            CGContextAddPath(ctx, path);
            CGContextFillPath(ctx);
            CGPathRelease(path);
        }
        _masks[m] = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        if (!_masks[m]) return NO;
    }
    return YES;
}

// Simple: L and R in their own lanes, linear; sample min/max around an RMS
// core. Split: one lane, L's levels up and R's down.
- (BOOL)buildSimpleMasks:(const analysis::Columns&)cols width:(size_t)width height:(size_t)height
                   scale:(CGFloat)scale {
    const simple::Shape shape = _split ? simple::splitShapeFor(cols) : simple::shapeFor(cols, _mono ? 1 : 2);
    const Lanes lanes = lanesFor(height, scale, shape.lanes);
    _laneCount = lanes.count;

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

// Classic: as the original styles drew, a 1 pt stroke per bucket out to
// the larger of |min| and |max|, mirrored about each half's centre. Mono:
// Solid averages the channels' min and max as it used to; Heat map and
// Rainbow take the larger channel. Mono tracks use one lane. Split: one
// lane, up to L's peak and down to R's.
- (BOOL)buildClassicMasks:(const analysis::Columns&)cols width:(size_t)width height:(size_t)height
                    scale:(CGFloat)scale {
    const analysis::Columns buckets = analysis::aggregateColumns(*self.waveformData, kClassicBuckets);
    if (buckets.count != kClassicBuckets) return NO;
    const bool stereo = buckets.channels == 2 && !_mono;
    const bool split = stereo && _split;
    const bool averageMono = _style == waveform_config::StyleSolid;
    const Lanes lanes = lanesFor(height, scale, stereo && !split ? 2 : 1, FamilyClassic);
    _laneCount = lanes.count;
    _classicSplit = split;

    // Peak of a column set (buckets, or the view's pixel columns) for a lane
    auto peakOf = [&](const analysis::Columns& c, size_t i, int lane) {
        if (stereo || c.channels == 1) {
            const int ch = stereo ? lane : 0;
            return std::max(-c.min[ch][i], c.max[ch][i]);
        }
        if (averageMono) {
            return std::max(-(c.min[0][i] + c.min[1][i]) * 0.5f, (c.max[0][i] + c.max[1][i]) * 0.5f);
        }
        return std::max(std::max(-c.min[0][i], -c.min[1][i]), std::max(c.max[0][i], c.max[1][i]));
    };

    CGContextRef ctx = createMaskContext(width, height);
    if (!ctx) return NO;
    CGContextSetLineWidth(ctx, scale);
    CGMutablePathRef path = CGPathCreateMutable();
    for (int l = 0; l < lanes.count; ++l) {
        for (size_t i = 0; i < kClassicBuckets; ++i) {
            const CGFloat up = std::min(1.0f, peakOf(buckets, i, l)) * lanes.amplitude;
            const CGFloat down = split ? std::min(1.0f, peakOf(buckets, i, 1)) * lanes.amplitude : up;
            if (up <= 0.0 && down <= 0.0) continue;
            const CGFloat x = (CGFloat)i / kClassicBuckets * width;
            CGPathMoveToPoint(path, NULL, x, lanes.center[l] - down);
            CGPathAddLineToPoint(path, NULL, x, lanes.center[l] + up);
        }
    }
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGPathRelease(path);
    _masks[MaskSimplePeak] = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);

    // Heat map colours per pixel column, from the bucket under it; per half in Split
    for (int l = 0; l < 2; ++l) _lanePeak[l].clear();
    for (int l = 0; l < (split ? 2 : lanes.count); ++l) {
        _lanePeak[l].resize(width);
        for (size_t c = 0; c < width; ++c) {
            const size_t i = std::min(kClassicBuckets - 1, (size_t)((c + 0.5) / width * kClassicBuckets));
            _lanePeak[l][c] = std::min(1.0f, peakOf(buckets, i, l));
        }
    }
    return _masks[MaskSimplePeak] != NULL;
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
        case StyleHeatMap:
        case StyleRainbow:
        case StyleSolid:
            return {};   // coloured per column or in bands in buildComposite
        default:   // the body is tinted per column in buildComposite
            return { flat(MaskPeakFill, t.accent, kPeakFillAlpha),
                     flat(MaskPeakEdge, t.accent, kPeakEdgeAlpha) };
    }
}

- (BOOL)buildComposite {
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, _maskWidth, _maskHeight, 8, 0, srgb,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(srgb);
    if (!ctx) return NO;

    const CGRect full = CGRectMake(0, 0, _maskWidth, _maskHeight);
    const CGFloat scale = [self backingScale];
    const Lanes lanes = lanesFor(_maskHeight, scale, _laneCount, _maskFamily);
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

    // Per-column colours: a one-pixel-high strip stretched over a band of
    // the image, through a mask
    auto drawStrip = [&](CGImageRef mask, CGRect band, auto colorAt) {
        std::vector<uint8_t> pixels(_maskWidth * 4);
        for (size_t c = 0; c < _maskWidth; ++c) {
            const theme::RGB col = colorAt(c);
            pixels[c * 4] = (uint8_t)std::lround(std::clamp(col.r, 0.0f, 1.0f) * 255);
            pixels[c * 4 + 1] = (uint8_t)std::lround(std::clamp(col.g, 0.0f, 1.0f) * 255);
            pixels[c * 4 + 2] = (uint8_t)std::lround(std::clamp(col.b, 0.0f, 1.0f) * 255);
            pixels[c * 4 + 3] = 255;
        }
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef strip = CGBitmapContextCreate(pixels.data(), _maskWidth, 1, 8, _maskWidth * 4, space,
                                                   (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(space);
        CGImageRef image = strip ? CGBitmapContextCreateImage(strip) : NULL;
        if (image) {
            CGContextSaveGState(ctx);
            CGContextClipToMask(ctx, full, mask);
            CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
            CGContextDrawImage(ctx, band, image);
            CGContextRestoreGState(ctx);
            CGImageRelease(image);
        }
        if (strip) CGContextRelease(strip);
    };

    // Layered: the body, tinted by each passage's spectral balance
    if (_maskFamily == FamilyLayered && _masks[MaskBody] && _bodyTint.size() == _maskWidth) {
        drawStrip(_masks[MaskBody], full, [&](size_t c) { return theme::tintColor(_tokens.accent, _bodyTint[c], _tintStrength); });
    }

    // Classic Solid: per lane, mirrored stepped bands of the accent from the
    // centre line out to full amplitude
    if (_maskFamily == FamilyClassic && _style == waveform_config::StyleSolid && _masks[MaskSimplePeak]
        && _gradientBands <= 0) {
        CGContextSaveGState(ctx);
        CGContextClipToMask(ctx, full, _masks[MaskSimplePeak]);
        setFill(ctx, _tokens.accent, 1.0);
        CGContextFillRect(ctx, full);
        CGContextRestoreGState(ctx);
    } else if (_maskFamily == FamilyClassic && _style == waveform_config::StyleSolid && _masks[MaskSimplePeak]) {
        const int kSolidBands = _gradientBands;
        std::vector<CGFloat> components, locations;
        auto stop = [&](CGFloat location, CGFloat alpha) {
            components.insert(components.end(), { _tokens.accent.r, _tokens.accent.g, _tokens.accent.b, alpha });
            locations.push_back(location);
        };
        for (int k = kSolidBands - 1; k >= 0; --k) {        // bottom edge up to the centre
            const CGFloat a = waveseek::bandAlpha(k, kSolidBands);
            stop(0.5 - (CGFloat)(k + 1) / kSolidBands * 0.5, a);
            stop(0.5 - (CGFloat)k / kSolidBands * 0.5, a);
        }
        for (int k = 0; k < kSolidBands; ++k) {             // centre up to the top edge
            const CGFloat a = waveseek::bandAlpha(k, kSolidBands);
            stop(0.5 + (CGFloat)k / kSolidBands * 0.5, a);
            stop(0.5 + (CGFloat)(k + 1) / kSolidBands * 0.5, a);
        }
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGGradientRef bands = CGGradientCreateWithColorComponents(space, components.data(), locations.data(),
                                                                  locations.size());
        CGColorSpaceRelease(space);
        for (int l = 0; bands && l < _laneCount && l < 2; ++l) {
            CGContextSaveGState(ctx);
            CGContextClipToMask(ctx, full, _masks[MaskSimplePeak]);
            CGContextClipToRect(ctx, CGRectMake(0, lanes.bottom[l], _maskWidth, lanes.height));
            CGContextDrawLinearGradient(ctx, bands, CGPointMake(0, lanes.center[l] - lanes.amplitude),
                                        CGPointMake(0, lanes.center[l] + lanes.amplitude),
                                        kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
            CGContextRestoreGState(ctx);
        }
        CGGradientRelease(bands);
    }

    // Classic: per lane, Heat map by the column's peak, Rainbow by position.
    // Split: L's colours above the centre line, R's below.
    if (_maskFamily == FamilyClassic && _style != waveform_config::StyleSolid && _masks[MaskSimplePeak]) {
        const CGFloat mid = std::round(lanes.center[0]);
        for (int l = 0; l < (_classicSplit ? 2 : _laneCount) && l < 2; ++l) {
            if (_lanePeak[l].size() != _maskWidth) continue;
            const CGRect band = !_classicSplit ? CGRectMake(0, lanes.bottom[l], _maskWidth, lanes.height)
                              : l == 0 ? CGRectMake(0, mid, _maskWidth, _maskHeight - mid)
                                       : CGRectMake(0, 0, _maskWidth, mid);
            drawStrip(_masks[MaskSimplePeak], band, [&](size_t c) {
                return _style == waveform_config::StyleHeatMap ? heatMapColor(_lanePeak[l][c])
                                                               : rainbowColor((c + 0.5f) / _maskWidth);
            });
        }
    }

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
            if (familyOf(_style) == FamilySimple) setFill(context, kBlack, 1.0);
            else CGContextSetFillColorWithColor(context, self.backgroundColor.CGColor);
            CGContextFillRect(context, bounds);
        } else if (bgAlpha > 0.0 && bgAlpha < 1.0) {
            CGContextSetFillColorWithColor(context, self.backgroundColor.CGColor);
            CGContextFillRect(context, bounds);
        }

        const bool hasWaveform = self.waveformData && self.waveformData->isValid();
        const CGRect wave = [self waveformRect];
        [self drawGuidesInContext:context rect:wave full:hasWaveform];

        if (hasWaveform) {
            [self drawWaveformInContext:context rect:wave];
        } else {
            [self drawPlaceholderInContext:context rect:wave];
        }

        if ([self rulerHeight] > 0) [self drawRulerInContext:context wave:wave];
        if (CGRectGetMaxX(wave) < CGRectGetMaxX(bounds)) [self drawLevelScaleInContext:context wave:wave];

        [self drawPlayedOverlayInContext:context rect:[self cursorRectFor:wave]];
        if (hasWaveform && _showClipMarkers) [self drawClipMarkersInContext:context rect:[self cursorRectFor:wave]];
        // The cursor runs through the margins too
        [self drawCursorInContext:context rect:[self cursorRectFor:wave]];
        if (hasWaveform) [self drawOverlaysInContext:context rect:wave];
    } @catch (NSException *e) {
        // An exception out of drawRect: takes foobar2000 down
        FB2K_console_formatter() << "[WaveSeek] Drawing failed: " << (e.reason ? e.reason.UTF8String : "?");
    }
}

// The waveform's part of the view, after the scales that are on and fit
// Height of the time ruler, 0 when it's off or doesn't fit
- (CGFloat)rulerHeight {
    return (_showTimeRuler && self.bounds.size.height >= TS(kRulerHeight) + kMinWaveformHeight)
        ? TS(kRulerHeight) : 0.0;
}

- (CGRect)waveformRect {
    CGRect r = self.bounds;
    const CGFloat ruler = [self rulerHeight];
    r.origin.y += ruler;
    r.size.height -= ruler;
    if (_showLevelScale && r.size.width >= TS(kGutterWidth) + kMinWaveformWidth) {
        r.size.width -= TS(kGutterWidth);
    }
    if (r.size.height >= kMinWaveformHeight + 2 * kWaveformMargin) {
        r = CGRectInset(r, 0, kWaveformMargin);
    }
    // On whole pixels: the composite is built at the pixel size and would be
    // resampled (blurred) into a rect that isn't, e.g. beside a 67.2 pt gutter
    return [self backingAlignedRect:r options:NSAlignAllEdgesNearest];
}

// The waveform's rect grown back over its top and bottom margins
- (CGRect)cursorRectFor:(CGRect)wave {
    const CGRect view = self.bounds;
    const CGFloat top = std::min(CGRectGetMaxY(view), CGRectGetMaxY(wave) + kWaveformMargin);
    const CGFloat bottom = std::max(view.origin.y, wave.origin.y - kWaveformMargin);
    return CGRectMake(wave.origin.x, bottom, wave.size.width, top - bottom);
}

- (CGFloat)backingScale {
    const CGFloat scale = self.window.backingScaleFactor;
    return scale > 0 ? scale : 2.0;
}

// Lanes the waveform is drawn in: two in Stereo, except that Layered and
// Classic give a mono track one; one in Mono and Split
- (int)laneCount {
    if (_mono || _split) return 1;
    if (familyOf(_style) == FamilySimple) return 2;
    return self.waveformData && self.waveformData->channelCount == 2 ? 2 : 1;
}

// Layered: each lane's centre line, and the -12 / -24 dB gridlines on both
// sides of it. Simple: each lane's centre line. Classic: none, as before.
- (void)drawGuidesInContext:(CGContextRef)context rect:(CGRect)rect full:(bool)full {
    const CGFloat scale = [self backingScale];
    auto snap = [&](CGFloat y) { return (std::floor(y * scale) + 0.5) / scale; };

    if (usesLanes(_style)) {
        if (familyOf(_style) != FamilySimple) return;   // Classic draws no guides
        const Lanes lanes = lanesFor(rect.size.height, 1.0, [self laneCount]);
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

    const Lanes lanes = lanesFor(rect.size.height, 1.0, [self laneCount], FamilyLayered);

    CGContextSaveGState(context);
    CGContextSetLineWidth(context, 1.0);
    if (full) {
        setStroke(context, _tokens.grid, 1.0);
        for (int l = 0; l < lanes.count; ++l) {
            const CGFloat centerY = rect.origin.y + lanes.center[l];
            for (float db : layered::kGridDb) {
                const CGFloat h = layered::fraction(db) * lanes.amplitude;
                for (CGFloat y : { centerY + h, centerY - h }) {
                    CGContextMoveToPoint(context, rect.origin.x, snap(y));
                    CGContextAddLineToPoint(context, CGRectGetMaxX(rect), snap(y));
                }
            }
        }
        CGContextStrokePath(context);
    }
    setStroke(context, _tokens.centre, 1.0);
    for (int l = 0; l < lanes.count; ++l) {
        const CGFloat y = snap(rect.origin.y + lanes.center[l]);
        CGContextMoveToPoint(context, rect.origin.x, y);
        CGContextAddLineToPoint(context, CGRectGetMaxX(rect), y);
    }
    CGContextStrokePath(context);
    CGContextRestoreGState(context);
}

- (void)drawWaveformInContext:(CGContextRef)context rect:(CGRect)rect {
    const CGSize pixelSize = [self convertSizeToBacking:rect.size];
    const size_t pixelW = (size_t)std::lround(pixelSize.width);
    const size_t pixelH = (size_t)std::lround(pixelSize.height);
    if (pixelW == 0 || pixelH == 0) return;

    if (pixelW != _maskWidth || pixelH != _maskHeight || !_masks[0] || _maskFamily != familyOf(_style) || _maskMono != _mono) {
        if (![self buildMasksWidth:pixelW height:pixelH]) return;
    }
    if (!_composite && ![self buildComposite]) return;

    CGContextDrawImage(context, rect, _composite);
}

#pragma mark - Played Part

// Dims the played part with an overlay of the background the style draws
// on, its edge at the cursor shaped by the cursor effect. The effects work
// in a rect at the origin, as they did before the redesign.
- (void)drawPlayedOverlayInContext:(CGContextRef)context rect:(CGRect)rect {
    if (!self.shadePlayedPortion || self.playedDimming <= 0.0 || self.playbackPosition <= 0.0) return;

    NSColor *dimBase = self.backgroundColor;
    if (self.glassBackground) {
        dimBase = [self isDarkAppearance] ? [NSColor blackColor] : [NSColor whiteColor];
    } else if (familyOf(_style) == FamilySimple) {
        dimBase = [NSColor blackColor];
    }
    NSColor *bgDeviceColor = [dimBase colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (!bgDeviceColor) return;

    const CGRect bounds = CGRectMake(0, 0, rect.size.width, rect.size.height);
    const CGFloat playedWidth = bounds.size.width * std::clamp(self.playbackPosition, 0.0, 1.0);
    const CGFloat dimOpacity = self.playedDimming;

    CGContextSaveGState(context);
    CGContextClipToRect(context, rect);
    CGContextTranslateCTM(context, rect.origin.x, rect.origin.y);
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
    CGContextRestoreGState(context);
}

// Get animation frequency: uses BPM if sync enabled, otherwise returns default
- (CGFloat)animationFrequencyWithDefault:(CGFloat)defaultHz {
    return waveseek::animationFrequency(self.bpmSync, self.trackBpm, defaultHz);
}

#pragma mark - Cursor Effects (as before the redesign)

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




- (void)drawPlaceholderInContext:(CGContextRef)context rect:(CGRect)rect {
    NSString *text = self.analyzing ? @"Analyzing..." : @"No waveform";
    NSDictionary *attrs = _placeholderAttributes;
    if ([self drawsOnBlack] && ![self isDarkAppearance]) {
        // The light-mode secondary label colour is dark grey
        NSMutableDictionary *onBlack = [attrs mutableCopy];
        onBlack[NSForegroundColorAttributeName] = [NSColor colorWithWhite:1.0 alpha:0.55];
        attrs = onBlack;
    }
    const NSSize size = [text sizeWithAttributes:attrs];
    [text drawAtPoint:NSMakePoint(CGRectGetMidX(rect) - size.width / 2, CGRectGetMidY(rect) - size.height / 2)
       withAttributes:attrs];
}

// 1 pt line, and the time in a chip beside it at the top
- (void)drawCursorInContext:(CGContextRef)context rect:(CGRect)rect {
    if (self.trackDuration <= 0.0 || (self.playbackPosition <= 0.0 && !self.playing)) return;

    const CGFloat scale = [self backingScale];
    const CGFloat position = std::clamp(self.playbackPosition, 0.0, 1.0);
    const CGFloat x = std::min((std::floor((rect.origin.x + rect.size.width * position) * scale) + 0.5) / scale,
                               CGRectGetMaxX(rect) - 0.5 / scale);

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
    NSString *time = str(overlay::formatClock(self.playbackPosition * self.trackDuration));
    const NSSize textSize = [time sizeWithAttributes:attrs];
    const CGFloat chipW = std::ceil(textSize.width + 2 * TS(kChipPadX));
    const CGFloat chipH = std::ceil(textSize.height + 2 * TS(kChipPadY));
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

    [time drawAtPoint:NSMakePoint(chip.origin.x + TS(kChipPadX), chip.origin.y + TS(kChipPadY)) withAttributes:attrs];
}

#pragma mark - Overlays

// 2 x 5 pt ticks on the top edge, one per clip run (one per pixel at most)
- (void)drawClipMarkersInContext:(CGContextRef)context rect:(CGRect)rect {
    const WaveformData& data = *self.waveformData;
    const double totalFrames = data.duration * data.sampleRate;
    if (data.clipRunFrames.empty() || totalFrames <= 0) return;

    const CGFloat scale = [self backingScale];
    CGContextSaveGState(context);
    [srgb(kOverlayAlert, _clipMarkerOpacity) setFill];
    long lastPixel = -1;
    for (uint64_t frame : data.clipRunFrames) {
        const CGFloat x = rect.origin.x + rect.size.width * (CGFloat)(frame / totalFrames);
        const long pixel = std::lround(x * scale);
        if (pixel == lastPixel) continue;
        lastPixel = pixel;
        const CGFloat left = std::round((x - kClipMarkerWidth / 2) * scale) / scale;
        CGContextFillRect(context, CGRectMake(left, CGRectGetMaxY(rect) - kClipMarkerHeight,
                                              kClipMarkerWidth, kClipMarkerHeight));
    }
    CGContextRestoreGState(context);
}

- (void)drawOverlaysInContext:(CGContextRef)context rect:(CGRect)rect {
    using namespace waveform_config;
    if (_summaryMode == SummaryAlways || (_summaryMode == SummaryOnHover && _hovering)) {
        [self drawSummaryInContext:context rect:rect];
    }
    if (_showReadout && _hovering && _readout.count > 0 && _hoverX < CGRectGetMaxX(rect)) {
        [self drawReadoutInContext:context rect:rect];
    }
}

- (void)fillOverlayBox:(CGRect)box radius:(CGFloat)radius context:(CGContextRef)context {
    CGContextSaveGState(context);
    const CGRect inner = CGRectInset(box, 0.5, 0.5);
    CGPathRef shape = CGPathCreateWithRoundedRect(inner, radius, radius, NULL);
    [srgb(kOverlayBackground, kOverlayBackgroundAlpha) setFill];
    CGContextAddPath(context, shape);
    CGContextFillPath(context);
    [srgb(kOverlayBorder) setStroke];
    CGContextSetLineWidth(context, 1.0);
    CGContextAddPath(context, shape);
    CGContextStrokePath(context);
    CGPathRelease(shape);
    CGContextRestoreGState(context);
}

- (NSAttributedString *)text:(NSString *)s color:(uint32_t)color bold:(BOOL)bold {
    return [[NSAttributedString alloc] initWithString:s attributes:@{
        NSFontAttributeName: bold ? _overlayBoldFont : _overlayFont,
        NSForegroundColorAttributeName: srgb(color)
    }];
}

// `I −12.4 LUFS  LRA 15.9 LU  TP +0.4 dBTP  PLR 12.8  17 clips`, bottom right
- (void)drawSummaryInContext:(CGContextRef)context rect:(CGRect)rect {
    const LoudnessSummary& s = self.waveformData->summary;
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] init];
    auto add = [&](NSString *text, uint32_t color) { [line appendAttributedString:[self text:text color:color bold:NO]]; };
    add(@"I ", kOverlayLabel);
    add(str(overlay::formatNumber(s.integrated, 1)), kOverlayValue);
    add(@" LUFS  LRA ", kOverlayLabel);
    add(str(overlay::formatNumber(s.range, 1)), kOverlayValue);
    add(@" LU  TP ", kOverlayLabel);
    add(str(overlay::formatNumber(s.truePeak, 1, true)), s.truePeak > 0.0f ? kOverlayAlert : kOverlayValue);
    add(@" dBTP  PLR ", kOverlayLabel);
    add(str(overlay::formatNumber(s.plr(), 1)), kOverlayValue);
    if (s.clipRuns > 0) {
        add([NSString stringWithFormat:@"  %u %@", s.clipRuns, s.clipRuns == 1 ? @"clip" : @"clips"], kOverlayAlert);
    }

    const NSSize size = line.size;
    const CGRect box = CGRectMake(std::round(CGRectGetMaxX(rect) - kBadgeInset - size.width - 2 * TS(kBadgePadX)),
                                  rect.origin.y + kBadgeInset,
                                  std::ceil(size.width + 2 * TS(kBadgePadX)), std::ceil(size.height + 2 * TS(kBadgePadY)));
    if (box.origin.x < rect.origin.x) return;   // narrower than the badge
    [self fillOverlayBox:box radius:kBadgeRadius context:context];
    [line drawAtPoint:NSMakePoint(box.origin.x + TS(kBadgePadX), box.origin.y + TS(kBadgePadY))];
}

// Dashed line at the mouse, and the readout for that column
- (void)drawReadoutInContext:(CGContextRef)context rect:(CGRect)rect {
    const CGFloat scale = [self backingScale];
    const CGFloat mouseX = std::clamp(_hoverX, rect.origin.x, CGRectGetMaxX(rect) - 1.0 / scale);
    const CGFloat lineX = (std::floor(mouseX * scale) + 0.5) / scale;

    CGContextSaveGState(context);
    setStroke(context, _tokens.cursor, 0.8);
    CGContextSetLineWidth(context, 1.0);
    const CGFloat dash[2] = { 3.0, 3.0 };
    CGContextSetLineDash(context, 0, dash, 2);
    const CGRect lineRect = [self cursorRectFor:rect];
    CGContextMoveToPoint(context, lineX, lineRect.origin.y);
    CGContextAddLineToPoint(context, lineX, CGRectGetMaxY(lineRect));
    CGContextStrokePath(context);
    CGContextRestoreGState(context);

    const analysis::Columns& r = _readout;
    const size_t c = std::min(r.count - 1, (size_t)std::max<CGFloat>(0.0, (mouseX - rect.origin.x) * scale));
    const double seconds = (mouseX - rect.origin.x) / std::max<CGFloat>(1.0, rect.size.width) * self.trackDuration;

    using namespace waveform_config;
    const CGFloat width = TS(overlay::kReadoutWidth);
    const CGFloat left = _readoutPosition == ReadoutFollowsMouse
        ? std::round(rect.origin.x + overlay::readoutX(mouseX - rect.origin.x, rect.size.width, width))
        : std::round(std::max(rect.origin.x, CGRectGetMaxX(rect) - kBadgeInset - width));

    // Room above `floor`: the view (it may reach over the ruler), or above the
    // summary badge at the bottom right. Drops the band section when the
    // whole box doesn't fit.
    bool onFloor = _readoutPosition == ReadoutBottomRight;
    CGFloat floor = self.bounds.origin.y;
    if (onFloor) {
        floor = rect.origin.y + kBadgeInset;
        if (_summaryMode != SummaryOff) {
            const CGFloat badge = std::ceil([@"I" sizeWithAttributes:@{ NSFontAttributeName: _overlayFont }].height
                                            + 2 * TS(kBadgePadY));
            floor += badge + kBadgeInset;
        }
        // Too short to fit above the badge: top right instead
        if (CGRectGetMaxY(self.bounds) - floor < TS(kReadoutCompactHeight)) {
            onFloor = false;
            floor = self.bounds.origin.y;
        }
    }
    const CGFloat room = CGRectGetMaxY(self.bounds) - floor;
    const bool bands = TS(kReadoutHeight) <= room;
    // Without the bands, as many value rows as fit (Corr goes first); in a
    // view too short even for the time, no box
    int rowCount = 4;
    auto compactHeight = [&](int rows) {
        return TS(rows > 0 ? kReadoutCompactHeight - (4 - rows) * kReadoutRowStep : kReadoutRowsY);
    };
    while (!bands && rowCount > 0 && compactHeight(rowCount) > room) --rowCount;
    const CGFloat height = bands ? TS(kReadoutHeight) : compactHeight(rowCount);
    if (height > room) return;
    // 10 pt from the top, less in views too short for that; at the bottom
    // right it sits on its floor instead
    const CGFloat topInset = std::clamp<CGFloat>((room - height) / 2, 0.0, overlay::kReadoutTop);
    const CGFloat top = onFloor ? floor + height
                                                               : CGRectGetMaxY(self.bounds) - topInset;
    [self fillOverlayBox:CGRectMake(left, top - height, width, height) radius:kReadoutRadius context:context];

    // Text rows hang from `y` points under the box's top
    auto drawLeft = [&](NSAttributedString *s, CGFloat y) {
        [s drawAtPoint:NSMakePoint(left + TS(kReadoutPadX), top - y - s.size.height)];
    };
    auto drawRight = [&](NSAttributedString *s, CGFloat y) {
        [s drawAtPoint:NSMakePoint(left + width - TS(kReadoutPadX) - s.size.width, top - y - s.size.height)];
    };
    auto drawCentre = [&](NSAttributedString *s, CGFloat y) {
        [s drawAtPoint:NSMakePoint(std::round(left + (width - s.size.width) / 2), top - y - s.size.height)];
    };

    drawLeft([self text:str(overlay::formatClock(seconds, true)) color:kOverlayValue bold:YES], TS(kReadoutHeaderY));
    drawRight([self text:@"click to seek" color:kOverlayLabel bold:NO], TS(kReadoutHeaderY));

    struct Row { NSString *label; std::string value; NSString *unit; };
    const Row rows[4] = {
        { @"LUFS-S", overlay::formatNumber(r.lufs[c], 1), @"" },
        { @"Peak", overlay::formatNumber(r.peakDb[c], 1), @" dBFS" },
        { @"Crest", overlay::formatNumber(r.crestDb[c], 1), @" dB" },
        { @"Corr", overlay::formatNumber(r.correlation[c], 2, true), @"" },
    };
    for (int i = 0; i < rowCount; ++i) {
        const CGFloat y = TS(kReadoutRowsY) + i * TS(kReadoutRowStep);
        drawLeft([self text:rows[i].label color:kOverlayLabel bold:NO], y);
        drawRight([self text:[str(rows[i].value) stringByAppendingString:rows[i].unit] color:kOverlayValue bold:NO], y);
    }

    if (!bands) return;

    // Lo / Mid / Hi: stacked bar, then the shares
    const CGRect bar = CGRectMake(left + TS(kReadoutPadX), top - TS(kReadoutBarY) - TS(kReadoutBarHeight),
                                  width - 2 * TS(kReadoutPadX), TS(kReadoutBarHeight));
    CGContextSaveGState(context);
    [srgb(kOverlayBorder) setFill];
    CGContextFillRect(context, bar);
    int percent[3] = { 0, 0, 0 };
    const bool known = !std::isnan(r.bandShare[0][c]);
    if (known) {
        CGFloat x = bar.origin.x;
        for (int b = 0; b < 3; ++b) {
            const CGFloat w = bar.size.width * r.bandShare[b][c];
            [srgb(kBandColors[b]) setFill];
            CGContextFillRect(context, CGRectMake(x, bar.origin.y, w, bar.size.height));
            x += w;
            percent[b] = (int)std::lround(r.bandShare[b][c] * 100.0);
        }
    }
    CGContextRestoreGState(context);

    auto band = [&](NSString *name, int b, NSString *suffix) {
        NSString *value = known ? [NSString stringWithFormat:@"%d", percent[b]] : str(overlay::formatNumber(NAN, 0));
        return [self text:[NSString stringWithFormat:@"%@ %@%@", name, value, suffix] color:kOverlayLabel bold:NO];
    };
    drawLeft(band(@"Lo", 0, @""), TS(kReadoutBandsY));
    drawCentre(band(@"Mid", 1, @""), TS(kReadoutBandsY));
    drawRight(band(@"Hi", 2, @" %"), TS(kReadoutBandsY));
}

#pragma mark - Scales

- (NSAttributedString *)scaleText:(NSString *)s {
    return [[NSAttributedString alloc] initWithString:s attributes:@{
        NSFontAttributeName: _overlayFont,
        NSForegroundColorAttributeName: srgb(kScaleLabel)
    }];
}

// Strip under the waveform: border, major ticks with m:ss labels, minor
// ticks at a quarter of the major interval
- (void)drawRulerInContext:(CGContextRef)context wave:(CGRect)wave {
    const CGFloat scale = [self backingScale];
    const CGFloat top = self.bounds.origin.y + [self rulerHeight];
    CGContextSaveGState(context);

    [srgb(kScaleBorder) setStroke];
    CGContextSetLineWidth(context, 1.0);
    const CGFloat borderY = (std::floor(top * scale) - 0.5) / scale;
    CGContextMoveToPoint(context, self.bounds.origin.x, borderY);
    CGContextAddLineToPoint(context, CGRectGetMaxX(self.bounds), borderY);
    CGContextStrokePath(context);

    const double duration = self.trackDuration;
    if (duration <= 0.0) {
        CGContextRestoreGState(context);
        return;
    }
    const double major = overlay::rulerInterval(duration, wave.size.width);
    const double minor = major / 4.0;
    [srgb(kScaleLabel, 0.6) setStroke];
    for (long i = 0; i * minor <= duration; ++i) {
        const CGFloat x = (std::floor((wave.origin.x + wave.size.width * (i * minor / duration)) * scale) + 0.5) / scale;
        const CGFloat length = (i % 4 == 0) ? kRulerMajorTick : kRulerMinorTick;
        CGContextMoveToPoint(context, x, top);
        CGContextAddLineToPoint(context, x, top - length);
    }
    CGContextStrokePath(context);

    for (long i = 0; i * major <= duration; ++i) {
        NSAttributedString *label = [self scaleText:str(overlay::formatClock(i * major))];
        const CGFloat x = wave.origin.x + wave.size.width * (i * major / duration) + TS(kRulerLabelGap);
        if (x + label.size.width > CGRectGetMaxX(wave)) break;
        [label drawAtPoint:NSMakePoint(std::round(x), top - TS(kRulerLabelTop) - label.size.height)];
    }
    CGContextRestoreGState(context);
}

// Gutter on the right. Layered: per lane 0 / -12 / -24 / -inf mirrored, with
// the unit. Simple and Classic: per lane 0 / -6 / -inf / -6 (-6 dB = half
// amplitude). L / R beside stereo lanes.
- (void)drawLevelScaleInContext:(CGContextRef)context wave:(CGRect)wave {
    const CGFloat gutterX = CGRectGetMaxX(wave);
    const CGFloat gutterRight = CGRectGetMaxX(self.bounds);
    struct Mark { CGFloat y; NSString *text; };
    std::vector<Mark> marks;
    NSString *minus = @"\u2212";
    NSString *minusInf = [minus stringByAppendingString:@"\u221E"];

    const Lanes lanes = lanesFor(wave.size.height, 1.0, [self laneCount], familyOf(_style));
    if (usesLanes(_style)) {
        for (int l = 0; l < lanes.count; ++l) {
            const CGFloat c = wave.origin.y + lanes.center[l], a = lanes.amplitude;
            marks.push_back({ c + a, @"0" });
            marks.push_back({ c + a / 2, [minus stringByAppendingString:@"6"] });
            marks.push_back({ c, minusInf });
            marks.push_back({ c - a / 2, [minus stringByAppendingString:@"6"] });
        }
        marks.push_back({ wave.origin.y + lanes.center[lanes.count - 1] - lanes.amplitude, @"0" });
    } else {
        for (int l = 0; l < lanes.count; ++l) {
            const CGFloat c = wave.origin.y + lanes.center[l], a = lanes.amplitude;
            marks.push_back({ c + a, @"0" });
            for (float db : layered::kGridDb) {
                marks.push_back({ c + layered::fraction(db) * a, str(overlay::formatNumber(db, 0)) });
            }
            marks.push_back({ c, minusInf });
            for (auto it = std::rbegin(layered::kGridDb); it != std::rend(layered::kGridDb); ++it) {
                marks.push_back({ c - layered::fraction(*it) * a, str(overlay::formatNumber(*it, 0)) });
            }
        }
        marks.push_back({ wave.origin.y + lanes.center[lanes.count - 1] - lanes.amplitude, @"0" });
    }

    // Top to bottom, centred on their level; the margins above and below
    // the waveform give the outermost ones room. Any that would overlap the
    // one above is skipped.
    const CGRect area = [self cursorRectFor:wave];
    CGFloat lastBottom = CGFLOAT_MAX;
    CGFloat topLabelY = CGRectGetMaxY(area);
    for (const Mark& m : marks) {
        NSAttributedString *label = [self scaleText:m.text];
        const CGFloat h = label.size.height;
        if (h > area.size.height) return;   // no room for any label
        const CGFloat y = std::clamp(m.y - h / 2, area.origin.y, CGRectGetMaxY(area) - h);
        if (lastBottom == CGFLOAT_MAX) topLabelY = y;
        if (y + h > lastBottom) continue;
        [label drawAtPoint:NSMakePoint(gutterX + TS(kGutterLabelX), y)];
        lastBottom = y;
    }

    // Unit (Layered) on the top row; channel names at the lane centres, or
    // half way up and down in Split
    if (!usesLanes(_style)) {
        NSAttributedString *unit = [self scaleText:@"dBFS"];
        [unit drawAtPoint:NSMakePoint(gutterRight - TS(kGutterChannelX) - unit.size.width, topLabelY)];
    }
    const bool splitNames = _split && self.waveformData && self.waveformData->channelCount == 2;
    if (lanes.count == 2 || splitNames) {
        NSString *names[2] = { @"L", @"R" };
        for (int l = 0; l < 2; ++l) {
            const CGFloat y = splitNames ? lanes.center[0] + (l == 0 ? 0.5 : -0.5) * lanes.amplitude : lanes.center[l];
            NSAttributedString *name = [self scaleText:names[l]];
            [name drawAtPoint:NSMakePoint(gutterRight - TS(kGutterChannelX) - name.size.width,
                                          wave.origin.y + y - name.size.height / 2)];
        }
    }
}

#pragma mark - Mouse Events

- (void)mouseEntered:(NSEvent *)event {
    _hovering = YES;
    _hoverX = [self convertPoint:event.locationInWindow fromView:nil].x;
    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)event {
    _hovering = YES;
    _hoverX = [self convertPoint:event.locationInWindow fromView:nil].x;
    if (_showReadout || _summaryMode == waveform_config::SummaryOnHover) [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    _hovering = NO;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    // Not on the level scale: clamped, a click there would seek to the end
    // and skip to the next track
    const CGFloat x = [self convertPoint:event.locationInWindow fromView:nil].x;
    _seeking = x < CGRectGetMaxX([self waveformRect]);
    if (_seeking) [self handleSeekWithEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
    _hoverX = [self convertPoint:event.locationInWindow fromView:nil].x;
    if (_seeking) [self handleSeekWithEvent:event];
}

- (void)mouseUp:(NSEvent *)event {
    _seeking = NO;
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
    const CGRect wave = [self waveformRect];
    CGFloat normalizedPosition = (location.x - wave.origin.x) / std::max<CGFloat>(1.0, wave.size.width);
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
