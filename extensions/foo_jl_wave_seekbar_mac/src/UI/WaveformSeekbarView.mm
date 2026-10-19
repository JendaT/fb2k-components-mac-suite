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
#include "../Core/OverlayText.h"
#include "../Core/ThemeTokens.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace {

// Style Layered: peak envelope fill and edge, then the loudness body tinted
// by the passage's spectral balance (theme::tintColor)
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

// Classic colours, as the original Heat map and Rainbow styles drew them.
// Heat map: blue (quiet) -> cyan -> green -> yellow -> red (loud).
theme::RGB heatMapColor(float amplitude) {
    const float a = std::clamp(amplitude, 0.0f, 1.0f);
    if (a < 0.25f) return { 0.0f, a / 0.25f, 1.0f };
    if (a < 0.5f)  return { 0.0f, 1.0f, 1.0f - (a - 0.25f) / 0.25f };
    if (a < 0.75f) return { (a - 0.5f) / 0.25f, 1.0f, 0.0f };
    return { 1.0f, 1.0f - (a - 0.75f) / 0.25f, 0.0f };
}

// Classic styles draw as the original did: 2048 one-point strokes at their
// bucket positions (the antialiasing gives them their fine texture), halves
// without a gap, peaks 4 pt from the edges
const size_t kClassicBuckets = 2048;
const CGFloat kClassicPadding = 4.0;

// Solid: the original gradient bands, alpha stepping down from the centre
// line to 40 % at full amplitude
const CGFloat kSolidEdgeAlpha = 0.4;

// Rainbow: fully saturated hue by position across the track, 0..1
theme::RGB rainbowColor(float position) {
    const float hue = std::fmod(std::max(0.0f, position), 1.0f) * 6.0f;
    const int sector = (int)hue % 6;
    const float f = hue - std::floor(hue);
    switch (sector) {
        case 0: return { 1.0f, f, 0.0f };
        case 1: return { 1.0f - f, 1.0f, 0.0f };
        case 2: return { 0.0f, 1.0f, f };
        case 3: return { 0.0f, 1.0f - f, 1.0f };
        case 4: return { f, 0.0f, 1.0f };
        default: return { 1.0f, 0.0f, 1.0f - f };
    }
}

const theme::RGB kBlack = { 0, 0, 0 };

// Lanes in a rect `height` high, `unit` per point: [0] = L on top, [1] = R
// below; one lane fills the rect. Simple: a gap between them, peaks almost
// to the edge. Classic: no gap, 4 pt padding.
struct Lanes {
    int count;
    CGFloat bottom[2], center[2];
    CGFloat height, amplitude;
};

Lanes lanesFor(CGFloat height, CGFloat unit, int count, bool classic = false) {
    Lanes l;
    l.count = count == 1 ? 1 : 2;
    const CGFloat gap = classic ? 0.0 : kLaneGap;
    l.height = l.count == 1 ? height : std::max<CGFloat>(0.0, (height - gap * unit) / 2.0);
    l.bottom[0] = height - l.height;
    l.bottom[1] = 0.0;
    for (int i = 0; i < l.count; ++i) l.center[i] = l.bottom[i] + l.height / 2.0;
    l.amplitude = std::max<CGFloat>(0.0, l.height / 2.0 - (classic ? kClassicPadding : kLaneInset) * unit);
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

void addEdge(CGMutablePathRef path, const std::vector<float>& frac, CGFloat centerY,
             CGFloat amplitude, CGFloat dir) {
    bool open = false;
    for (size_t c = 0; c < frac.size(); ++c) {
        const CGFloat h = frac[c] * amplitude;
        if (h < 0.5 || frac[c] >= kEdgeCeiling) { open = false; continue; }
        const CGPoint p = CGPointMake(c + 0.5, centerY + dir * h);
        if (open) CGPathAddLineToPoint(path, NULL, p.x, p.y);
        else CGPathMoveToPoint(path, NULL, p.x, p.y);
        open = true;
    }
}

} // namespace

@interface WaveformSeekbarView () {
    NSTrackingArea *_trackingArea;
    NSFont *_overlayFont;
    NSFont *_overlayBoldFont;
    CGFloat _textScale;          // overlay text size / 10 pt

    // Mouse over the view, for the readout and the summary badge
    BOOL _hovering;
    CGFloat _hoverX;
    BOOL _showReadout;
    int _readoutPosition;
    float _tintStrength;
    int _summaryMode;
    BOOL _showClipMarkers;
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
    std::vector<float> _lanePeak[2];   // Classic: peak per column and lane, for the colours
    int _laneCount;
    int _gradientBands;                // Classic Solid
    std::vector<float> _bodyTint;      // Layered: tint position per column
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
    // Classic styles mix mono differently from each other
    if (familyOf(newStyle) != familyOf(_style) || (familyOf(newStyle) == FamilyClassic && newStyle != _style)) {
        [self invalidateMasks];
    }
    _style = newStyle;
    _mono = getConfigInt(kKeyChannelMode, kDefaultChannelMode) == ChannelsMono;
    const int64_t opacity = getConfigInt(kKeyPlayedOpacity, kDefaultPlayedOpacity);
    _playedOpacity = std::clamp<int64_t>(opacity, kMinPlayedOpacity, kMaxPlayedOpacity) / 100.0;
    _showCursorTime = getConfigBool(kKeyCursorTime, kDefaultCursorTime);
    _gradientBands = (int)getConfigInt(kKeyGradientBands, kDefaultGradientBands);
    if (std::find(std::begin(kGradientBandChoices), std::end(kGradientBandChoices), _gradientBands)
        == std::end(kGradientBandChoices)) {
        _gradientBands = kDefaultGradientBands;
    }
    _tintStrength = kBodyTintStrength[std::clamp<int64_t>(getConfigInt(kKeyBodyTint, kDefaultBodyTint),
                                                          BodyTintOff, BodyTintStrong)];
    _showReadout = getConfigBool(kKeyHoverReadout, kDefaultHoverReadout);
    _readoutPosition = (int)std::clamp<int64_t>(getConfigInt(kKeyReadoutPosition, kDefaultReadoutPosition),
                                                ReadoutFollowsMouse, ReadoutBottomRight);
    _summaryMode = (int)std::clamp<int64_t>(getConfigInt(kKeySummaryMode, kDefaultSummaryMode), SummaryOff, SummaryAlways);
    _showClipMarkers = getConfigBool(kKeyClipMarkers, kDefaultClipMarkers);

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
    if (familyOf(_style) == FamilySimple) {
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

// Layered: L up, R down on one dBFS axis; peak envelope (fill and edge)
// around the short-term loudness body
- (BOOL)buildLayeredMasks:(const analysis::Columns&)cols width:(size_t)width height:(size_t)height
                    scale:(CGFloat)scale {
    const layered::Shape shape = layered::shapeFor(cols);
    _bodyTint = layered::tintPositions(cols);
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

// Simple: L and R in their own lanes, linear; sample min/max around an RMS
// core.
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

// Classic: as the original styles drew, a 1 pt stroke per bucket out to
// the larger of |min| and |max|, mirrored about each half's centre. Mono:
// Solid averages the channels' min and max as it used to; Heat map and
// Rainbow take the larger channel. Mono tracks use one lane.
- (BOOL)buildClassicMasks:(const analysis::Columns&)cols width:(size_t)width height:(size_t)height
                    scale:(CGFloat)scale {
    const analysis::Columns buckets = analysis::aggregateColumns(*self.waveformData, kClassicBuckets);
    if (buckets.count != kClassicBuckets) return NO;
    const bool stereo = buckets.channels == 2 && !_mono;
    const bool averageMono = _style == waveform_config::StyleSolid;
    const Lanes lanes = lanesFor(height, scale, stereo ? 2 : 1, true);
    _laneCount = lanes.count;

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
            const CGFloat h = std::min(1.0f, peakOf(buckets, i, l)) * lanes.amplitude;
            if (h <= 0.0) continue;
            const CGFloat x = (CGFloat)i / kClassicBuckets * width;
            CGPathMoveToPoint(path, NULL, x, lanes.center[l] - h);
            CGPathAddLineToPoint(path, NULL, x, lanes.center[l] + h);
        }
    }
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGPathRelease(path);
    _masks[MaskSimplePeak] = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);

    // Heat map colours per pixel column, from the bucket under it
    for (int l = 0; l < 2; ++l) _lanePeak[l].clear();
    for (int l = 0; l < lanes.count; ++l) {
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
    const Lanes lanes = _maskFamily == FamilyClassic
        ? lanesFor(_maskHeight, scale, _laneCount, true)
        : lanesFor(_maskHeight, scale, _maskMono ? 1 : 2);
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
                                                   kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
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
            const CGFloat a = 1.0 - (CGFloat)k / kSolidBands * (1.0 - kSolidEdgeAlpha);
            stop(0.5 - (CGFloat)(k + 1) / kSolidBands * 0.5, a);
            stop(0.5 - (CGFloat)k / kSolidBands * 0.5, a);
        }
        for (int k = 0; k < kSolidBands; ++k) {             // centre up to the top edge
            const CGFloat a = 1.0 - (CGFloat)k / kSolidBands * (1.0 - kSolidEdgeAlpha);
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

    // Classic: per lane, Heat map by the column's peak, Rainbow by position
    if (_maskFamily == FamilyClassic && _style != waveform_config::StyleSolid && _masks[MaskSimplePeak]) {
        for (int l = 0; l < _laneCount && l < 2; ++l) {
            if (_lanePeak[l].size() != _maskWidth) continue;
            drawStrip(_masks[MaskSimplePeak], CGRectMake(0, lanes.bottom[l], _maskWidth, lanes.height), [&](size_t c) {
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
    return r;
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

// Layered: centre line, and the -12 / -24 dB gridlines in each half.
// Simple: each lane's centre line. Classic: none, as before.
- (void)drawGuidesInContext:(CGContextRef)context rect:(CGRect)rect full:(bool)full {
    const CGFloat scale = [self backingScale];
    auto snap = [&](CGFloat y) { return (std::floor(y * scale) + 0.5) / scale; };

    if (usesLanes(_style)) {
        if (familyOf(_style) != FamilySimple) return;   // Classic draws no guides
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

    if (pixelW != _maskWidth || pixelH != _maskHeight || !_masks[0] || _maskFamily != familyOf(_style) || _maskMono != _mono) {
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
    [srgb(kOverlayAlert) setFill];
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
    const CGFloat height = bands ? TS(kReadoutHeight) : TS(kReadoutCompactHeight);
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
    for (int i = 0; i < 4; ++i) {
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

// Gutter on the right. Layered: 0 / -12 / -24 / -inf mirrored, with the
// unit. Simple: per lane 0 / -6 / -inf / -6 (-6 dB = half amplitude) and L / R.
- (void)drawLevelScaleInContext:(CGContextRef)context wave:(CGRect)wave {
    const CGFloat gutterX = CGRectGetMaxX(wave);
    const CGFloat gutterRight = CGRectGetMaxX(self.bounds);
    struct Mark { CGFloat y; NSString *text; };
    std::vector<Mark> marks;
    NSString *minus = @"\u2212";
    NSString *minusInf = [minus stringByAppendingString:@"\u221E"];

    if (usesLanes(_style)) {
        const bool classic = familyOf(_style) == FamilyClassic;
        const int count = classic ? ((self.waveformData && self.waveformData->channelCount == 2 && !_mono) ? 2 : 1)
                                  : (_mono ? 1 : 2);
        const Lanes lanes = lanesFor(wave.size.height, 1.0, count, classic);
        for (int l = 0; l < lanes.count; ++l) {
            const CGFloat c = wave.origin.y + lanes.center[l], a = lanes.amplitude;
            marks.push_back({ c + a, @"0" });
            marks.push_back({ c + a / 2, [minus stringByAppendingString:@"6"] });
            marks.push_back({ c, minusInf });
            marks.push_back({ c - a / 2, [minus stringByAppendingString:@"6"] });
        }
        marks.push_back({ wave.origin.y + lanes.center[lanes.count - 1] - lanes.amplitude, @"0" });
    } else {
        const CGFloat c = CGRectGetMidY(wave);
        const CGFloat a = std::max<CGFloat>(0.0, wave.size.height / 2.0 - kHalfInset);
        marks.push_back({ c + a, @"0" });
        for (float db : layered::kGridDb) {
            marks.push_back({ c + layered::fraction(db) * a, str(overlay::formatNumber(db, 0)) });
        }
        marks.push_back({ c, minusInf });
        for (auto it = std::rbegin(layered::kGridDb); it != std::rend(layered::kGridDb); ++it) {
            marks.push_back({ c - layered::fraction(*it) * a, str(overlay::formatNumber(*it, 0)) });
        }
        marks.push_back({ c - a, @"0" });
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
        const CGFloat y = std::clamp(m.y - h / 2, area.origin.y, CGRectGetMaxY(area) - h);
        if (lastBottom == CGFLOAT_MAX) topLabelY = y;
        if (y + h > lastBottom) continue;
        [label drawAtPoint:NSMakePoint(gutterX + TS(kGutterLabelX), y)];
        lastBottom = y;
    }

    // Unit (Layered) on the top row; channel names (Simple, stereo) at the lane centres
    if (!usesLanes(_style)) {
        NSAttributedString *unit = [self scaleText:@"dBFS"];
        [unit drawAtPoint:NSMakePoint(gutterRight - TS(kGutterChannelX) - unit.size.width, topLabelY)];
    } else if (!_mono && !(familyOf(_style) == FamilyClassic && self.waveformData && self.waveformData->channelCount != 2)) {
        const Lanes lanes = lanesFor(wave.size.height, 1.0, 2, familyOf(_style) == FamilyClassic);
        NSString *names[2] = { @"L", @"R" };
        for (int l = 0; l < 2; ++l) {
            NSAttributedString *name = [self scaleText:names[l]];
            [name drawAtPoint:NSMakePoint(gutterRight - TS(kGutterChannelX) - name.size.width,
                                          wave.origin.y + lanes.center[l] - name.size.height / 2)];
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
    [self handleSeekWithEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
    _hoverX = [self convertPoint:event.locationInWindow fromView:nil].x;
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
