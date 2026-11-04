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
#include "../Core/MaskPaths.h"
#include "../Core/SimpleShape.h"
#include "../Core/OverlayText.h"
#include "../Core/WaveformColorMap.h"
#include "../Core/WaveformGeometry.h"
#include "../Core/GradientBandTable.h"
#include "../Core/ThemeTokens.h"
#include "../Core/ZoomRange.h"
#include "../Core/PhraseMarkers.h"
#include "../Core/BeatJump.h"
#include "../Core/CursorFx.h"
#include "CursorEffectPainter.h"
#include "../Integration/BeatLoop.h"
#include "../../../../shared/ThemeColor.h"
#include "../../../../shared/jl_beatgrid_api.h"
#include <algorithm>
#include <cmath>
#include <climits>
#include <memory>
#include <vector>

namespace analysis = waveseek::analysis;
namespace fx = waveseek::fx;
namespace layered = waveseek::layered;
namespace masks = waveseek::masks;
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
const size_t kClassicStrokeRun = 256;
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


// How one mask is coloured: flat, or a vertical gradient mirrored around
// each lane's centre (edge, mid, centre, mid, edge)
struct Paint {
    int mask;
    theme::RGB edge, mid, centre;
    CGFloat alpha;
    bool laneGradient;
};

// Theme colours are Display P3 (shared/ThemeColor.h), like the other
// visualisers', so they show at full saturation on wide-gamut screens.
CGColorSpaceRef themeSpace() {
    static CGColorSpaceRef space = JLCreateThemeColorSpace();
    return space;
}

void setFill(CGContextRef ctx, const theme::RGB& c, CGFloat alpha) {
    const CGFloat comps[4] = { c.r, c.g, c.b, alpha };
    CGContextSetFillColorSpace(ctx, themeSpace());
    CGContextSetFillColor(ctx, comps);
}

void setStroke(CGContextRef ctx, const theme::RGB& c, CGFloat alpha) {
    const CGFloat comps[4] = { c.r, c.g, c.b, alpha };
    CGContextSetStrokeColorSpace(ctx, themeSpace());
    CGContextSetStrokeColor(ctx, comps);
}

fx::Colour fxColour(const theme::RGB& c) {
    return { c.r, c.g, c.b };
}

// Firewall's own colours, the same in every theme
const fx::Colour kFireGlow = { 1.0, 0.42, 0.08 };
const fx::Colour kFireCore = { 1.0, 0.80, 0.40 };

NSString *str(const std::string& s) {
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

NSColor *p3(uint32_t rgb, CGFloat alpha = 1.0) {
    return [NSColor colorWithDisplayP3Red:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0
                                     blue:(rgb & 0xFF) / 255.0 alpha:alpha];
}

// Overlays keep their own dark palette in every theme
const uint32_t kOverlayBackground = 0x13110C;
const CGFloat kOverlayBackgroundAlpha = 0.95;
const uint32_t kOverlayBorder = 0x3A3326;
const uint32_t kOverlayValue = 0xF2E9D6;
const uint32_t kOverlayLabel = 0x9A907D;
const uint32_t kOverlayAlert = 0xF0603F;     // TP above 0, clips
const uint32_t kOverlayWarning = 0xE5A50A;   // phrase markers drifting off the grid
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

// The bottom bar's controls: segments in one box at the bottom right,
// groups apart by a gap with a hairline in it; the loop's colour
const CGFloat kBarSegmentPadX = 5.0;
const CGFloat kBarGroupGap = 7.0;
const CGFloat kBarIconSize = 11.0;
const CGFloat kBeatSnapPoints = 6.0;        // with the mixer on, a click this near a beat seeks to it
const double kLoopLookahead = 2.5 / 60.0;   // the loop's end within 2.5 position checks: seek on time
const double kSeekLanded = 0.15;            // the playback position this near a seek's target shows it
const double kSeekTimeout = 1.0;            // a seek not shown by then is taken as done
const double kDeckMargin = 0.05;            // a splice target this far inside the DSP's audio, at least
const uint32_t kLoopColor = 0x35C27A;

// Zoom: vertical scroll and pinch zoom about the pointer, horizontal scroll
// pans. A wheel notch is one line; trackpad scroll comes in points.
const double kZoomOctavesPerLine = 0.25;        // ~1.19x per notch
const double kZoomOctavesPerPoint = 0.01;       // 2x per 100 pt
const CGFloat kPanPointsPerLine = 10.0;
const CGFloat kEffectReach = 50.0;              // cursor effects reach 40 pt from the cursor

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

// The outline of the heights, broken where they drop under half a pixel so
// silence leaves only the centre line, and where they sit at full scale so a
// track limited to 0 dBFS doesn't draw a flat line along the top
const float kEdgeCeiling = 0.995f;   // within ~0.2 dB of 0 dBFS on the -36 dB axis

// Stroked kEdgeChunk columns at a time: one path with a vertex per pixel
// column takes CoreGraphics 0.1-0.35 s to stroke, on the main thread, and
// runs of 16 take about half as long as runs of 64. Each run starts where
// the last one ended; round caps close the joins.
const size_t kEdgeChunk = 16;

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

// The bottom bar, left to right: with the mixer, the jumps with the size
// menu among them and the loop (of that size); always the cog with the
// controls' and the zoom's modes
typedef NS_ENUM(NSInteger, BarControl) {
    BarControlNone = 0,
    BarControlBack32,
    BarControlBack16,
    BarControlBackSize,
    BarControlSizeMenu,
    BarControlForwardSize,
    BarControlForward16,
    BarControlForward32,
    BarControlLoop,
    BarControlCog,
};

struct BarSegment {
    BarControl control = BarControlNone;
    NSString *title = nil;      // nil: an icon
    bool groupStart = false;    // a gap and a hairline before it
    CGRect rect = CGRectZero;
};

@interface WaveformSeekbarView () {
    NSTrackingArea *_trackingArea;
    CGColorSpaceRef _deviceRGBColorSpace;       // Cached for the cursor effects' gradients
    NSFont *_overlayFont;
    NSFont *_overlayBoldFont;
    CGFloat _textScale;          // overlay text size / 10 pt

    // Mouse over the view, for the readout and the summary badge
    BOOL _hovering;
    CGFloat _hoverX, _hoverY;
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
    // The experimental cursor effects: their drawing and images, the
    // track's level envelope (for the waveform data it was built from) and
    // this frame's sparks
    std::unique_ptr<fx::Painter> _fxPainter;
    fx::LevelEnvelope _fxLevels;
    const WaveformData *_fxLevelsFor;
    std::vector<fx::Spark> _sparks;
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

    // The part of the track the waveform shows, and the part the masks show
    // (more than that while the view follows the cursor, so it can move
    // without rebuilding them) with the view's zoom and pixel width they
    // were built for, and where they were last drawn, in pixels from the
    // waveform's left edge
    waveseek::ZoomRange _zoom;
    waveseek::ZoomRange _maskZoom;
    double _maskViewZoom;
    size_t _maskViewWidth;
    long _maskOffsetPx;
    size_t _classicBuckets;
    // Following the cursor: the spot it stays at (a fraction across; taken
    // where the cursor is when it comes into view), and when the zoom last
    // changed (masks for following wait for a pause)
    double _followSpot;
    bool _followSpotSet;
    CFAbsoluteTime _lastZoomChange;
    bool _zoomEnabled;

    // Phrase markers: settings, the markers for the grid shown, and where
    // they were drawn this frame (for the readout)
    bool _phraseMarkers;
    int _phraseLength;
    bool _phraseBreakColours;
    bool _phraseFollowGrid;     // markers and beat-synced effects follow a new grid
    std::vector<waveseek::PhraseMarker> _phrases;
    const waveseek::PhraseGrid *_phrasesFor;
    int _phraseBeatsDrawn;
    std::vector<std::pair<CGFloat, size_t>> _phraseHits;   // x, index into _phrases
    int _phraseNoneLogged;

    // The bottom bar: the cog's controls and zoom modes, and whether BPM
    // Analyzer is there for the mixer. The mixer: the loop and jump size,
    // the beats of the grid shown, the loop, and a seek sent but not yet in
    // the playback position
    int _controlsMode;
    int _followMode;
    bool _haveBeatGrids;
    bool _barMenuOpen;
    NSMutableDictionary<NSString *, NSImage *> *_barIcons;   // by symbol and colour
    int _beatSize;
    std::vector<double> _beats;
    const waveseek::PhraseGrid *_beatsFor;
    bool _beatsFollow;
    double _beatsDuration;
    waveseek::BeatLoop _loop;
    unsigned _loopGeneration;       // a scheduled seek to the start is for this loop
    bool _loopEndScheduled;
    double _pendingSeek;            // NAN when none
    CFAbsoluteTime _pendingSince;
    // The loop DSP: its status as of the last position check, the seek
    // whose timeline the cursor follows, a seek of ours on its way, a
    // request on its way and the seek that replaces it when turned down,
    // the track time being measured, the low-latency hint
    beatloop::Status _deck;
    uint64_t _deckEpoch;
    uint64_t _armId;
    CFAbsoluteTime _armAt;
    CFAbsoluteTime _loopCheckAfter;
    uint64_t _requestId;
    double _fallbackTarget;
    bool _fallbackHasThen;
    waveseek::LoopAction _fallbackThen;
    std::vector<double> _syncSamples;
    uint64_t _syncEpoch;
    bool _lowLatency;
    CFAbsoluteTime _latencyNoteAt;
    // The visualisation clock less the audio actually heard (measured while
    // the audio is untouched; 0 when the clock is exact)
    double _clockOffset;
    std::vector<double> _clockSamples;
    bool _jumpMovesLoop;
    CFAbsoluteTime _loopRearmAt;
    CFAbsoluteTime _timingNoteAt;
    bool _wasInsideLoop;            // playback was in the loop at the last check (seek-based looping)
    double _measuredLag;
    // Option-dragging the loop: the beat under the mouse when it began, the
    // loop then, and where it would go
    bool _loopDragging;
    double _loopDragBeat;
    waveseek::BeatLoop _loopDragOrigin;
    waveseek::BeatLoop _loopDragPreview;
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

    _pendingSeek = NAN;
    _followSpot = 0.5;
    jl_beatgrid::ptr grids;
    _haveBeatGrids = fb2k::std_api_try_get(grids);

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
    _cursorEffect = (WaveformCursorEffect)cursorEffectFromStored(getConfigInt(kKeyCursorEffect, kDefaultCursorEffect));
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
    _zoomEnabled = getConfigBool(kKeyZoomEnabled, kDefaultZoomEnabled);
    if (!_zoomEnabled) _zoom.reset();
    _phraseMarkers = getConfigBool(kKeyPhraseMarkers, kDefaultPhraseMarkers);
    _phraseLength = getConfigInt(kKeyPhraseLength, kDefaultPhraseLength) == 16 ? 16 : 32;
    _phraseBreakColours = getConfigBool(kKeyPhraseBreakColours, kDefaultPhraseBreakColours);
    _phraseFollowGrid = getConfigBool(kKeyPhraseFollowGrid, kDefaultPhraseFollowGrid);
    _phraseBeatsDrawn = 0;   // rebuild the markers
    _controlsMode = (int)std::clamp<int64_t>(getConfigInt(kKeyControlsMode, kDefaultControlsMode), ControlsNone,
                                             ControlsAnalytics);
    _followMode = (int)std::clamp<int64_t>(getConfigInt(kKeyZoomFollow, kDefaultZoomFollow), FollowNone, FollowCentre);
    if (_followMode != FollowCentre) _zoom.clampToTrack();
    [self followCursor];
    const int64_t size = getConfigInt(kKeyBeatSize, waveseek::kDefaultBeatSize);
    _beatSize = std::find(std::begin(waveseek::kBeatSizeChoices), std::end(waveseek::kBeatSizeChoices), size)
                    != std::end(waveseek::kBeatSizeChoices) ? (int)size : waveseek::kDefaultBeatSize;
    _barIcons = nil;   // the text size may have changed
    if (_controlsMode != ControlsMixer) [self endLoop];
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

    _waveformColor = JLColorFromARGB(waveARGB);
    _backgroundColor = JLColorFromARGB(bgARGB);

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
    _fxLevels.clear();
    _fxLevelsFor = nullptr;
    if (!waveformData) _zoom.reset();   // a new track, or none
    [self invalidateMasks];
}

- (void)setWaveformDetail:(const WaveformDetail *)waveformDetail {
    if (waveformDetail == _waveformDetail) return;
    _waveformDetail = waveformDetail;
    [self invalidateMasks];
}

- (void)setPhraseGrid:(const waveseek::PhraseGrid *)phraseGrid {
    _phraseGrid = phraseGrid;
    _phrases.clear();
    _phrasesFor = nullptr;
    _phraseHits.clear();
    _beatsFor = nullptr;
    _beats.clear();
    [self endLoop];   // its beats are another grid's, or none
    [self setNeedsDisplay:YES];
}

// The fine detail, when it belongs to the waveform shown
- (const WaveformDetail *)usableDetail {
    return _waveformDetail && _waveformData && _waveformDetail->matches(*_waveformData) ? _waveformDetail : nullptr;
}

- (double)zoomFactor {
    return _zoom.zoom;
}

// Masks `width` pixels wide for `range` of the track, at the scale of a
// view `viewWidth` pixels wide at the current zoom
- (BOOL)buildMasksForRange:(const waveseek::ZoomRange &)range width:(size_t)width height:(size_t)height
                 viewWidth:(size_t)viewWidth {
    [self invalidateMasks];
    _maskZoom = range;
    _maskViewZoom = _zoom.zoom;
    _maskViewWidth = viewWidth;
    // Classic keeps its bucket count per view width
    _classicBuckets = std::max<size_t>(1, (size_t)std::lround((double)kClassicBuckets * width / std::max<size_t>(1, viewWidth)));
    analysis::Columns cols = analysis::aggregateColumns(*self.waveformData, width, _maskZoom.start, _maskZoom.end(),
                                                        [self usableDetail]);
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
            masks::fillInRuns(ctx, width, [&](size_t c0, size_t c1) {
                for (int l = 0; l < lanes.count; ++l) {
                    for (int half = 0; half < 2; ++half) {
                        const int ch = channelOf(l, half);
                        const std::vector<float>& frac = m == MaskPeakFill ? shape.peak[ch] : shape.body[ch];
                        masks::addHalfShape(ctx, frac, c0, c1, lanes.center[l], lanes.amplitude, dirs[half]);
                    }
                }
            });
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
        masks::fillInRuns(ctx, width, [&](size_t c0, size_t c1) {
            for (int l = 0; l < shape.lanes; ++l) {
                const simple::Lane& lane = shape.lane[l];
                if (m == MaskSimplePeak) masks::addBand(ctx, lane.top, lane.bottom, c0, c1, lanes.center[l], lanes.amplitude);
                else masks::addBand(ctx, lane.coreTop, lane.coreBottom, c0, c1, lanes.center[l], lanes.amplitude);
            }
        });
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
    const size_t bucketCount = _classicBuckets;
    const analysis::Columns buckets = analysis::aggregateColumns(*self.waveformData, bucketCount,
                                                                 _maskZoom.start, _maskZoom.end(), [self usableDetail]);
    if (buckets.count != bucketCount) return NO;
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
    // Stroked kClassicStrokeRun buckets at a time: all 4096 strokes in one
    // path take CoreGraphics 20-60 ms. Where two runs meet, the neighbouring
    // strokes' overlap is blended instead of merged, a few pixels slightly off.
    CGContextSetLineWidth(ctx, scale);
    for (size_t i0 = 0; i0 < bucketCount; i0 += kClassicStrokeRun) {
        const size_t i1 = std::min(bucketCount, i0 + kClassicStrokeRun);
        for (int l = 0; l < lanes.count; ++l) {
            for (size_t i = i0; i < i1; ++i) {
                const CGFloat up = std::min(1.0f, peakOf(buckets, i, l)) * lanes.amplitude;
                const CGFloat down = split ? std::min(1.0f, peakOf(buckets, i, 1)) * lanes.amplitude : up;
                if (up <= 0.0 && down <= 0.0) continue;
                const CGFloat x = (CGFloat)i / bucketCount * width;
                CGContextMoveToPoint(ctx, x, lanes.center[l] - down);
                CGContextAddLineToPoint(ctx, x, lanes.center[l] + up);
            }
        }
        CGContextStrokePath(ctx);
    }
    _masks[MaskSimplePeak] = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);

    // Heat map colours per pixel column, from the bucket under it; per half in Split
    for (int l = 0; l < 2; ++l) _lanePeak[l].clear();
    for (int l = 0; l < (split ? 2 : lanes.count); ++l) {
        _lanePeak[l].resize(width);
        for (size_t c = 0; c < width; ++c) {
            const size_t i = std::min(bucketCount - 1, (size_t)((c + 0.5) / width * bucketCount));
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
    CGColorSpaceRef space = JLCreateThemeColorSpace();
    CGContextRef ctx = CGBitmapContextCreate(NULL, _maskWidth, _maskHeight, 8, 0, space,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    if (!ctx) return NO;

    const CGRect full = CGRectMake(0, 0, _maskWidth, _maskHeight);
    const CGFloat scale = [self backingScale];
    const Lanes lanes = lanesFor(_maskHeight, scale, _laneCount, _maskFamily);
    CGColorSpaceRef gradientSpace = JLCreateThemeColorSpace();

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
        CGColorSpaceRef space = JLCreateThemeColorSpace();
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
        CGColorSpaceRef space = JLCreateThemeColorSpace();
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
                return _style == waveform_config::StyleHeatMap
                    ? heatMapColor(_lanePeak[l][c])
                    : rainbowColor((float)_maskZoom.positionAt((c + 0.5) / _maskWidth));
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
            // Under the played part's dimming and the cursor
            [self drawPhraseMarkersInContext:context rect:[self cursorRectFor:wave]];
        } else {
            [self drawPlaceholderInContext:context rect:wave];
        }

        if ([self rulerHeight] > 0) [self drawRulerInContext:context wave:wave];
        if (CGRectGetMaxX(wave) < CGRectGetMaxX(bounds)) [self drawLevelScaleInContext:context wave:wave];

        [self drawPlayedOverlayInContext:context rect:[self cursorRectFor:wave]];
        if (hasWaveform) [self drawLoopInContext:context rect:[self cursorRectFor:wave]];
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

    // The part of the track in view (less than the view when centring
    // shows space beyond its ends), and a pixel's share of the track
    const double grid = _zoom.span() / pixelW;
    const double from = std::max(0.0, _zoom.start), to = std::min(1.0, _zoom.end());
    if (!(to > from)) return;
    const bool covered = _masks[0] && pixelH == _maskHeight && _maskFamily == familyOf(_style) && _maskMono == _mono &&
                         _maskViewWidth == pixelW && _maskViewZoom == _zoom.zoom &&
                         from >= _maskZoom.start - grid / 2 && to <= _maskZoom.end() + grid / 2;
    if (!covered) {
        // Following, once the zoom has settled: a view's width more on each
        // side, on whole pixels of the track; else just what is in view
        double m0 = from, m1 = to;
        if ([self following] && CFAbsoluteTimeGetCurrent() - _lastZoomChange > 0.25) {
            m0 = std::max(0.0, std::floor((_zoom.start - _zoom.span()) / grid) * grid);
            m1 = std::min(1.0, _zoom.end() + _zoom.span());
        }
        waveseek::ZoomRange range;
        range.zoom = 1.0 / (m1 - m0);
        range.start = m0;
        const size_t width = std::max<size_t>(1, (size_t)std::lround((m1 - m0) / grid));
        if (![self buildMasksForRange:range width:width height:pixelH viewWidth:pixelW]) return;
    }
    if (!_composite && ![self buildComposite]) return;

    // At whole pixels, so the composite is never resampled
    const CGFloat scale = [self backingScale];
    _maskOffsetPx = std::lround((_maskZoom.start - _zoom.start) / grid);
    const CGRect dest = CGRectMake(rect.origin.x + _maskOffsetPx / scale, rect.origin.y, _maskWidth / scale, rect.size.height);
    CGContextSaveGState(context);
    CGContextClipToRect(context, rect);
    CGContextDrawImage(context, dest, _composite);
    CGContextRestoreGState(context);
}

// Zoomed in with a follow mode on
- (BOOL)following {
    return _zoomEnabled && _zoom.zoomed() && _followMode != waveform_config::FollowNone;
}

// Moves the view with the cursor (see ZoomRange::centreOn, followAt), on
// whole pixels
- (void)followCursor {
    if (![self following]) return;
    const double pixels = [self convertSizeToBacking:[self waveformRect].size].width;
    const double grid = pixels >= 1.0 ? _zoom.span() / pixels : 0.0;
    const double position = std::clamp(_playbackPosition, 0.0, 1.0);
    if (_followMode == waveform_config::FollowCentre) {
        _zoom.centreOn(position, grid);
        return;
    }
    // Held where it is while in view; where it comes into view next time
    const double across = _zoom.acrossOf(position);
    if (across < 0.0 || across > 1.0) {
        _followSpotSet = false;
        return;
    }
    if (!_followSpotSet) {
        _followSpot = across;
        _followSpotSet = true;
    }
    _zoom.followAt(position, _followSpot, grid);
}

// After the user moves or zooms the view: where the cursor is becomes the
// spot it is kept at, when it is in view
- (void)takeFollowSpot {
    const double across = _zoom.acrossOf(std::clamp(_playbackPosition, 0.0, 1.0));
    _followSpotSet = across >= 0.0 && across <= 1.0;
    if (_followSpotSet) _followSpot = across;
}

- (void)setPlaybackPosition:(double)playbackPosition {
    _playbackPosition = playbackPosition;
    [self followCursor];
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

    // Zoomed in, the cursor can be off either side: nothing played in view,
    // or all of it, with the effects at the cursor kept out of sight
    const CGRect bounds = CGRectMake(0, 0, rect.size.width, rect.size.height);
    const double across = _zoom.acrossOf(std::clamp(self.playbackPosition, 0.0, 1.0));
    if (across <= 0.0) return;
    const CGFloat playedWidth = across > 1.0 ? bounds.size.width + kEffectReach : bounds.size.width * across;
    const CGFloat dimOpacity = self.playedDimming;

    // Only over the track: a centred view shows space beyond its ends
    const CGFloat trackLeft = rect.origin.x + rect.size.width * std::max(0.0, _zoom.acrossOf(0.0));
    const CGFloat trackRight = rect.origin.x + rect.size.width * std::min(1.0, _zoom.acrossOf(1.0));
    // The waveform's rect in the effects' coordinates, for those that follow it
    const CGRect wave = CGRectOffset([self waveformRect], -rect.origin.x, -rect.origin.y);
    CGContextSaveGState(context);
    CGContextClipToRect(context, CGRectMake(trackLeft, rect.origin.y, std::max<CGFloat>(0.0, trackRight - trackLeft),
                                            rect.size.height));
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
        case WaveformCursorEffectShimmer:
            [self drawShimmerEffectInContext:context bounds:bounds playedWidth:playedWidth
                                     bgColor:bgDeviceColor dimOpacity:dimOpacity];
            break;
        case WaveformCursorEffectParticles:
            [self drawParticlesEffectInContext:context bounds:bounds playedWidth:playedWidth
                                       bgColor:bgDeviceColor dimOpacity:dimOpacity wave:wave];
            break;
        case WaveformCursorEffectFirewall:
            [self drawFirewallEffectInContext:context bounds:bounds playedWidth:playedWidth
                                      bgColor:bgDeviceColor dimOpacity:dimOpacity];
            break;
        case WaveformCursorEffectEarthcrusher:
            [self drawEarthcrusherEffectInContext:context bounds:bounds playedWidth:playedWidth
                                          bgColor:bgDeviceColor dimOpacity:dimOpacity wave:wave];
            break;
    }
    CGContextRestoreGState(context);
}

// The grid at the playback position: following a new grid when the
// markers do
- (waveseek::GridAt)gridAtPlayback {
    return waveseek::gridAt(*_phraseGrid, self.playbackPosition * self.trackDuration, _phraseFollowGrid);
}

// The animation rate: with sync on, the beat grid's tempo when there is one
// (the section playing), else the BPM tag's; otherwise the effect's own default
- (CGFloat)animationFrequencyWithDefault:(CGFloat)defaultHz {
    if (self.bpmSync && _phraseGrid && _phraseGrid->summary.bpm > 0.0) {
        const waveseek::GridAt grid = [self gridAtPlayback];
        if (grid.bpm > 0.0) return grid.bpm / 60.0;
    }
    return waveseek::animationFrequency(self.bpmSync, self.trackBpm, defaultHz);
}

// The effects' clock. With sync on and a beat grid, while playing: the
// playback position counted from the grid's anchor, a quarter beat ahead, so
// a sine at the beat rate peaks exactly on every beat. Otherwise wall time.
- (double)animationTime {
    if (self.bpmSync && self.isPlaying && _phraseGrid && _phraseGrid->summary.bpm > 0.0 && self.trackDuration > 0.0) {
        const waveseek::GridAt grid = [self gridAtPlayback];
        if (grid.bpm > 0.0) {
            return waveseek::beatSyncedTime(self.playbackPosition * self.trackDuration, grid.anchorSeconds, grid.bpm);
        }
    }
    return CFAbsoluteTimeGetCurrent();
}

#pragma mark - Cursor Effects (as before the redesign)

// Effect 0: None - Sharp transition, uniform dimming
- (void)drawNoneEffectInContext:(CGContextRef)context bounds:(CGRect)bounds
                    playedWidth:(CGFloat)playedWidth bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity {
    NSColor *dimColor = [bgColor colorWithAlphaComponent:dimOpacity];
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
        NSColor *dimColor = [bgColor colorWithAlphaComponent:dimOpacity];
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

// Effect 2: Glow - a bloom centred on the cursor line, fading with distance,
// pulsing (on the beat with sync on). On a dark background it lightens what
// is under it, the waveform too; on a light one the accent's haze is kept
// faint, as it darkens.
- (void)drawGlowEffectInContext:(CGContextRef)context bounds:(CGRect)bounds
                    playedWidth:(CGFloat)playedWidth bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity {
    [self drawNoneEffectInContext:context bounds:bounds playedWidth:playedWidth bgColor:bgColor dimOpacity:dimOpacity];
    const float pulse = (float)waveseek::oscillator([self animationTime], [self animationFrequencyWithDefault:1.0]);
    const bool dark = [self effectsOnDark];
    [self fxPainter].glow(context, bounds, playedWidth, fxColour(_tokens.accent),
                          fxColour(dark ? _tokens.hot : _tokens.cursor), pulse, dark ? 1.0f : 0.5f, dark);
}

// Effect 3: Scanline - Animated lines traveling near cursor
- (void)drawScanlineEffectInContext:(CGContextRef)context bounds:(CGRect)bounds
                        playedWidth:(CGFloat)playedWidth bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity {
    // Draw solid dimming first
    NSColor *dimColor = [bgColor colorWithAlphaComponent:dimOpacity];
    CGContextSetFillColorWithColor(context, dimColor.CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, playedWidth, bounds.size.height));

    NSColor *waveDeviceColor = [self.waveformColor colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (!waveDeviceColor) return;

    // Animated scanlines traveling near cursor
    CGFloat time = [self animationTime];
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
    CGFloat time = [self animationTime];
    CGFloat freq = [self animationFrequencyWithDefault:1.5] * 2.0 * M_PI;  // Default 1.5Hz
    CGFloat breath = 0.5 + 0.5 * sin(time * freq);

    // Modulate dimOpacity: ranges from dimOpacity*0.3 to dimOpacity*1.0
    CGFloat pulsingOpacity = dimOpacity * (0.3 + breath * 0.7);

    NSColor *dimColor = [bgColor colorWithAlphaComponent:pulsingOpacity];
    CGContextSetFillColorWithColor(context, dimColor.CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, playedWidth, bounds.size.height));
}

// Effect 6: Shimmer - Oscillating brightness bands
- (void)drawShimmerEffectInContext:(CGContextRef)context bounds:(CGRect)bounds
                       playedWidth:(CGFloat)playedWidth bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity {
    // Draw base dimming
    NSColor *dimColor = [bgColor colorWithAlphaComponent:dimOpacity * 0.7];
    CGContextSetFillColorWithColor(context, dimColor.CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, playedWidth, bounds.size.height));

    // Draw shimmering bands near cursor
    CGFloat time = [self animationTime];
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

#pragma mark - Cursor Effects (experimental)

- (fx::Painter &)fxPainter {
    if (!_fxPainter) _fxPainter = std::make_unique<fx::Painter>(themeSpace());
    return *_fxPainter;
}

// The background the effects draw over is dark: their light then lightens
// what is under it rather than painting over it
- (bool)effectsOnDark {
    return theme::isDark(_tokens.background);
}

// The track's level envelope, built from its fine blocks on first use
- (const fx::LevelEnvelope &)fxLevels {
    const WaveformData *data = self.waveformData;
    if (data != _fxLevelsFor) {
        _fxLevels.clear();
        _fxLevelsFor = data;
        if (data && data->isValid() && data->sampleRate > 0 && data->blockFrames > 0) {
            const bool stereo = data->channelCount == 2 && data->blockRms[1].size() == data->blockRms[0].size();
            _fxLevels.build(data->blockRms[0].data(), stereo ? data->blockRms[1].data() : nullptr,
                            data->blockRms[0].size(), (double)data->blockFrames / data->sampleRate);
        }
    }
    return _fxLevels;
}

// How far the waveform reaches above and below a lane's centre at x (points
// from its left edge), roughly as each style draws it, for sparks thrown
// off its edge
- (void)edgesAtX:(CGFloat)x lane:(int)lane amplitude:(CGFloat)amplitude top:(CGFloat *)top bottom:(CGFloat *)bottom {
    *top = *bottom = 0.0;
    const analysis::Columns& r = _readout;
    const long c = (long)std::floor(x * [self backingScale]) - _maskOffsetPx;
    if (r.channels == 0 || c < 0 || c >= (long)r.count) return;
    const bool two = r.channels == 2;
    auto up = [&](int ch) { return std::max(0.0f, r.max[ch][c]); };
    auto down = [&](int ch) { return std::max(0.0f, -r.min[ch][c]); };
    float t, b;
    if (_split) {
        t = std::max(up(0), down(0));
        b = two ? std::max(up(1), down(1)) : t;
    } else if ([self laneCount] == 1) {
        t = two ? std::max(up(0), up(1)) : up(0);
        b = two ? std::max(down(0), down(1)) : down(0);
    } else {
        const int ch = two ? lane : 0;
        t = up(ch);
        b = down(ch);
    }
    switch (familyOf(_style)) {
        case FamilyLayered: {
            // Mirrored on a dBFS axis; in Split L up, R down
            auto frac = [](float peak) { return layered::fraction(peak > 0.0f ? 20.0f * std::log10(peak) : -INFINITY); };
            if (_split) {
                t = frac(t);
                b = frac(b);
            } else {
                t = b = frac(std::max(t, b));
            }
            break;
        }
        case FamilyClassic:
            if (!_split) t = b = std::max(t, b);
            break;
        case FamilySimple:
            break;
    }
    *top = std::min(1.0f, t) * amplitude;
    *bottom = std::min(1.0f, b) * amplitude;
}

// Where sparks go: the cursor's x at a playback time, and the waveform's
// lanes and edges, in the effects' coordinates
- (fx::SparkGeometry)sparkGeometryForBounds:(CGRect)bounds wave:(CGRect)wave {
    fx::SparkGeometry g;
    const Lanes lanes = lanesFor(wave.size.height, 1.0, [self laneCount], familyOf(_style));
    g.lanes = lanes.count;
    for (int l = 0; l < lanes.count; ++l) g.centre[l] = wave.origin.y + lanes.center[l];
    g.amplitude = lanes.amplitude;
    g.xAt = [self cursorXAtTimeForWidth:bounds.size.width];
    const CGFloat amplitude = lanes.amplitude;
    g.edges = [self, amplitude](CGFloat x, int lane, CGFloat& top, CGFloat& bottom) {
        [self edgesAtX:x lane:lane amplitude:amplitude top:&top bottom:&bottom];
    };
    return g;
}

// The cursor's x at a playback time (seconds), across `width`
- (std::function<CGFloat(double)>)cursorXAtTimeForWidth:(CGFloat)width {
    const waveseek::ZoomRange zoom = _zoom;
    const double duration = self.trackDuration;
    return [zoom, duration, width](double t) {
        return duration > 0.0 ? (CGFloat)(width * zoom.acrossOf(t / duration)) : (CGFloat)NAN;
    };
}

// Effect 7: Particles - sparks thrown off the waveform at the cursor, more and
// farther the louder the track is there, so they burst on its beats by
// themselves. A function of the playback time: nothing kept between frames.
- (void)drawParticlesEffectInContext:(CGContextRef)context bounds:(CGRect)bounds playedWidth:(CGFloat)playedWidth
                             bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity wave:(CGRect)wave {
    [self drawNoneEffectInContext:context bounds:bounds playedWidth:playedWidth bgColor:bgColor dimOpacity:dimOpacity];
    const fx::LevelEnvelope& levels = [self fxLevels];
    if (levels.empty() || self.trackDuration <= 0.0) return;
    fx::sparksAt(self.playbackPosition * self.trackDuration, fx::particleSparks(),
                 [&levels](double t) { return levels.burst(t); }, _sparks);
    const bool dark = [self effectsOnDark];
    [self fxPainter].sparks(context, _sparks, [self sparkGeometryForBounds:bounds wave:wave],
                            fxColour(dark ? _tokens.hot : _tokens.deep), fxColour(_tokens.accent), dark);
}

// The pulse of Firewall and Earthcrusher: 0..1, on the beat with sync on
- (float)effectPulse {
    return (float)waveseek::oscillator([self animationTime], [self animationFrequencyWithDefault:1.5]);
}

// The track's smoothed level now, 0..1; middling without a waveform
- (float)effectLevel {
    const fx::LevelEnvelope& levels = [self fxLevels];
    if (levels.empty() || self.trackDuration <= 0.0) return 0.5f;
    return std::min(1.0f, levels.smooth(self.playbackPosition * self.trackDuration));
}

// The track's smoothed level at x across `width`, 0..1; middling without a
// waveform
- (std::function<float(CGFloat)>)levelAtXForWidth:(CGFloat)width {
    const fx::LevelEnvelope& levels = [self fxLevels];
    const waveseek::ZoomRange zoom = _zoom;
    const double duration = self.trackDuration;
    if (levels.empty() || duration <= 0.0 || width <= 0.0) return [](CGFloat) { return 0.5f; };
    return [&levels, zoom, duration, width](CGFloat x) {
        return std::min(1.0f, levels.smooth(zoom.positionAt(x / width) * duration));
    };
}

// Effect 8: Firewall - the played part burns: a row of fires behind the
// cursor, each as tall as the track is loud there and taller near the
// cursor, with the warm light and embers at the cursor, all under the loop
// and markers. The cursor's own fire, the tallest, stands on it
// (drawEffectCursorInContext), from the same field, stepped here.
- (void)drawFirewallEffectInContext:(CGContextRef)context bounds:(CGRect)bounds playedWidth:(CGFloat)playedWidth
                            bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity {
    [self drawNoneEffectInContext:context bounds:bounds playedWidth:playedWidth bgColor:bgColor dimOpacity:dimOpacity];
    const bool dark = [self effectsOnDark];
    fx::Painter& painter = [self fxPainter];
    const float pulse = [self effectPulse];
    // Higher where the track is loud, flaring with the pulse
    painter.stepFire(bounds, 0.35f + 0.8f * [self effectLevel] + 0.25f * pulse, CFAbsoluteTimeGetCurrent());
    painter.fireRow(context, bounds, playedWidth, bounds.size.width * _zoom.acrossOf(0.0), [self backingScale],
                    [self levelAtXForWidth:bounds.size.width]);
    painter.glow(context, bounds, playedWidth, kFireGlow, kFireCore, pulse, 0.8f, dark, 0.0f);
    if (self.trackDuration <= 0.0) return;
    const fx::LevelEnvelope& levels = [self fxLevels];
    fx::sparksAt(self.playbackPosition * self.trackDuration, fx::emberSparks(),
                 [&levels](double t) { return 0.4f + levels.burst(t); }, _sparks);
    painter.embers(context, _sparks, bounds, [self cursorXAtTimeForWidth:bounds.size.width], dark);
}

// Earthcrusher's colours: the waveform's own, burnt (fx::earthShades)
- (fx::EarthColours)earthColours {
    const fx::EarthShades s = fx::earthShades(_tokens.accent);
    return { fxColour(s.plate), fxColour(s.crack), fxColour(s.clod), fxColour(s.ember), fxColour(s.core) };
}

// Effect 9: Earthcrusher - behind the jagged cursor (drawEffectCursorInContext)
// the 20-40 pt of waveform it just went over lies scorched and cracked, the
// freshest cracks still glowing, longer where the track is loud; clods and
// hot bits are kicked up on its beats. All in shades of the wave colour.
- (void)drawEarthcrusherEffectInContext:(CGContextRef)context bounds:(CGRect)bounds playedWidth:(CGFloat)playedWidth
                                bgColor:(NSColor *)bgColor dimOpacity:(CGFloat)dimOpacity wave:(CGRect)wave {
    [self drawNoneEffectInContext:context bounds:bounds playedWidth:playedWidth bgColor:bgColor dimOpacity:dimOpacity];
    if (!_masks[0] || _maskWidth == 0) return;   // no waveform drawn to crack
    fx::Painter& painter = [self fxPainter];
    const float level = [self effectLevel];
    const CGFloat zone = 20.0 + 20.0 * level;
    const float flicker = 0.75f + 0.25f * fx::noise1((float)std::fmod(CFAbsoluteTimeGetCurrent(), 1000.0) * 9.0f, 77u);
    // The waveform's silhouette where it was drawn; the cracks anchored at
    // the track's start so they stay put on it as the zone moves along
    const CGFloat scale = [self backingScale];
    const CGRect maskRect = CGRectMake(_maskOffsetPx / scale, wave.origin.y, _maskWidth / scale, wave.size.height);
    const fx::EarthColours colours = [self earthColours];
    painter.scorch(context, CGRectMake(playedWidth - zone, wave.origin.y, zone, wave.size.height), _masks[0], maskRect,
                   scale, bounds.size.width * _zoom.acrossOf(0.0), 0.6f + 0.4f * level, flicker, colours,
                   [self effectsOnDark]);
    const fx::LevelEnvelope& levels = [self fxLevels];
    if (levels.empty() || self.trackDuration <= 0.0) return;
    fx::sparksAt(self.playbackPosition * self.trackDuration, fx::debrisSparks(),
                 [&levels](double t) { return levels.burst(t); }, _sparks);
    painter.sparks(context, _sparks, [self sparkGeometryForBounds:bounds wave:wave], colours.ember, colours.clod, false);
}

// Firewall and Earthcrusher draw the cursor themselves while the played part
// (and so the effect) shows
- (BOOL)effectDrawsCursor {
    if (!self.shadePlayedPortion || self.playedDimming <= 0.0 || self.playbackPosition <= 0.0) return NO;
    return self.cursorEffect == WaveformCursorEffectFirewall || self.cursorEffect == WaveformCursorEffectEarthcrusher;
}

// The cursor at x in `rect` as the effect draws it: flames, or a jagged line
- (void)drawEffectCursorInContext:(CGContextRef)context rect:(CGRect)rect x:(CGFloat)x {
    fx::Painter& painter = [self fxPainter];
    if (self.cursorEffect == WaveformCursorEffectFirewall) {
        painter.fireWall(context, rect, x);
    } else {
        painter.jaggedCursor(context, rect, x, CFAbsoluteTimeGetCurrent(), 2.0f + 2.5f * [self effectPulse] +
                             1.5f * [self effectLevel], [self earthColours]);
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
    const double across = _zoom.acrossOf(std::clamp(self.playbackPosition, 0.0, 1.0));
    if (across < 0.0 || across > 1.0) return;   // zoomed in on another part
    const CGFloat x = std::min((std::floor((rect.origin.x + rect.size.width * across) * scale) + 0.5) / scale,
                               CGRectGetMaxX(rect) - 0.5 / scale);

    if ([self effectDrawsCursor]) {
        [self drawEffectCursorInContext:context rect:rect x:x];
    } else {
        CGContextSaveGState(context);
        setStroke(context, _tokens.cursor, 1.0);
        CGContextSetLineWidth(context, 1.0);
        CGContextMoveToPoint(context, x, rect.origin.y);
        CGContextAddLineToPoint(context, x, CGRectGetMaxY(rect));
        CGContextStrokePath(context);
        CGContextRestoreGState(context);
    }

    if (!self.showCursorTime) return;
    NSDictionary *attrs = @{
        NSFontAttributeName: _chipFont,
        NSForegroundColorAttributeName: [NSColor colorWithDisplayP3Red:_tokens.cursorText.r
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

#pragma mark - Phrase Markers

// A hairline at every phrase start, coloured by how well the beats sit on
// the grid there: quiet when locked, a warning tick when drifting, an alert
// tick when broken, dashed and dim without pulse, and a triangle on the top
// edge where a new grid begins. On the master grid, or following each new
// grid (its own tempo and phrase count). Thinned to keep them
// kMinPhraseSpacing apart; neutral when colours are off or the tempo is
// uncertain.
- (void)drawPhraseMarkersInContext:(CGContextRef)context rect:(CGRect)rect {
    _phraseHits.clear();
    if (!_phraseMarkers || !_phraseGrid || !(self.trackDuration > 0.0)) {
        // Diagnostic: why none are drawn, once per reason
        const int reason = !_phraseMarkers ? 1 : !_phraseGrid ? 2 : 3;
        if (reason != _phraseNoneLogged) {
            _phraseNoneLogged = reason;
            FB2K_console_formatter() << "[WaveSeek] Phrase markers: none drawn ("
                                     << (reason == 1 ? "switched off" : reason == 2 ? "no beat grid in the view" : "no track length")
                                     << ")";
        }
        return;
    }
    _phraseNoneLogged = 0;
    const jl_beatgrid_summary &grid = _phraseGrid->summary;
    const int beats = waveseek::thinnedPhraseBeats(_phraseLength, waveseek::densestBpm(*_phraseGrid, _phraseFollowGrid),
                                                   self.trackDuration, rect.size.width, _zoom.zoom);
    if (beats != _phraseBeatsDrawn || _phrasesFor != _phraseGrid) {
        _phrases = waveseek::phraseMarkers(*_phraseGrid, beats, _phraseFollowGrid);
        _phraseBeatsDrawn = beats;
        _phrasesFor = _phraseGrid;
        size_t inView = 0;
        for (const waveseek::PhraseMarker &m : _phrases) {
            const double a = _zoom.acrossOf(m.seconds / self.trackDuration);
            inView += a >= 0.0 && a <= 1.0;
        }
        FB2K_console_formatter() << "[WaveSeek] Phrase markers: " << _phrases.size() << " every " << beats << " beats, "
                                 << inView << " in view, " << pfc::format_int(std::lround(rect.size.width)) << " pt wide, "
                                 << (_phrases.empty() ? 0.0 : _phrases.front().seconds) << " s first, "
                                 << _phraseGrid->bars.size() << " bars";
    }
    const bool neutral = !_phraseBreakColours || grid.tempo_strength < jl_beatgrid_uncertain_strength;
    const CGFloat scale = [self backingScale];
    const CGFloat hairline = 1.0 / scale;
    auto xAt = [&](double seconds) {
        return (std::floor((rect.origin.x + rect.size.width * _zoom.acrossOf(seconds / self.trackDuration)) * scale)
                + 0.5) / scale;
    };

    CGContextSaveGState(context);
    CGContextSetLineWidth(context, hairline);
    long lastPixel = LONG_MIN;
    for (size_t i = 0; i < _phrases.size(); ++i) {
        const waveseek::PhraseMarker &m = _phrases[i];
        const double across = _zoom.acrossOf(m.seconds / self.trackDuration);
        if (across < 0.0 || across > 1.0) continue;
        const CGFloat x = xAt(m.seconds);
        const long pixel = std::lround(x * scale);
        if (pixel == lastPixel) continue;   // one per pixel column
        lastPixel = pixel;
        _phraseHits.push_back({ x, i });

        const jl_phrase_state state = neutral ? jl_phrase_locked : m.state;
        switch (state) {
            case jl_phrase_drifting: [p3(kOverlayWarning, 0.55) setStroke]; break;
            case jl_phrase_broken: [p3(kOverlayAlert, 0.65) setStroke]; break;
            case jl_phrase_no_pulse: setStroke(context, _tokens.centre, 0.35); break;
            default: setStroke(context, _tokens.centre, 0.6); break;
        }
        if (state == jl_phrase_no_pulse) {
            const CGFloat dash[2] = { 2.0, 3.0 };
            CGContextSetLineDash(context, 0, dash, 2);
        } else {
            CGContextSetLineDash(context, 0, nullptr, 0);
        }
        CGContextMoveToPoint(context, x, rect.origin.y);
        CGContextAddLineToPoint(context, x, CGRectGetMaxY(rect));
        CGContextStrokePath(context);

        // Ticks on the bottom edge (clip markers own the top)
        if (state == jl_phrase_drifting || state == jl_phrase_broken) {
            [(state == jl_phrase_broken ? p3(kOverlayAlert) : p3(kOverlayWarning)) setFill];
            const CGFloat left = std::round((x - kClipMarkerWidth / 2) * scale) / scale;
            CGContextFillRect(context, CGRectMake(left, rect.origin.y, kClipMarkerWidth, kClipMarkerHeight));
        }
        // Where the new grid begins, on the top edge
        if (state == jl_phrase_reanchor && !std::isnan(m.reanchorSeconds)) {
            const double at = _zoom.acrossOf(m.reanchorSeconds / self.trackDuration);
            if (at >= 0.0 && at <= 1.0) {
                const CGFloat tx = xAt(m.reanchorSeconds), top = CGRectGetMaxY(rect);
                [p3(kOverlayWarning) setFill];
                CGContextMoveToPoint(context, tx - 3.5, top);
                CGContextAddLineToPoint(context, tx + 3.5, top);
                CGContextAddLineToPoint(context, tx, top - 5.0);
                CGContextClosePath(context);
                CGContextFillPath(context);
            }
        }
    }
    CGContextRestoreGState(context);
}

// The readout's line about the phrase marker under the mouse, if any
- (NSAttributedString *)phraseLineNear:(CGFloat)x {
    const std::pair<CGFloat, size_t> *nearest = nullptr;
    for (const auto &hit : _phraseHits) {
        if (std::fabs(hit.first - x) <= 4.0 && (!nearest || std::fabs(hit.first - x) < std::fabs(nearest->first - x))) {
            nearest = &hit;
        }
    }
    if (!nearest) return nil;
    const waveseek::PhraseMarker &m = _phrases[nearest->second];
    const bool neutral = !_phraseBreakColours || _phraseGrid->summary.tempo_strength < jl_beatgrid_uncertain_strength;
    if (m.state == jl_phrase_no_pulse && !neutral) return [self text:@"No pulse" color:kOverlayLabel bold:NO];
    if (m.phrase < 0) {   // where a section's grid begins
        NSMutableAttributedString *line = [[NSMutableAttributedString alloc] init];
        [line appendAttributedString:[self text:@"New grid · " color:kOverlayLabel bold:NO]];
        [line appendAttributedString:[self text:str(overlay::formatNumber(m.bpm, 2))
                                          color:neutral ? kOverlayValue : kOverlayWarning bold:NO]];
        [line appendAttributedString:[self text:@" BPM" color:kOverlayLabel bold:NO]];
        return line;
    }
    NSString *where = [NSString stringWithFormat:@"Phrase %ld · bar %ld · ", m.phrase + 1, m.startBar + 1];
    NSString *what = m.state == jl_phrase_reanchor ? @"new grid"
                   : [NSString stringWithFormat:@"%@ ms", str(overlay::formatNumber(m.offsetMs, 0, true))];
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] init];
    [line appendAttributedString:[self text:where color:kOverlayLabel bold:NO]];
    const uint32_t color = neutral ? kOverlayValue
                         : m.state == jl_phrase_broken ? kOverlayAlert
                         : m.state == jl_phrase_drifting || m.state == jl_phrase_reanchor ? kOverlayWarning : kOverlayValue;
    [line appendAttributedString:[self text:what color:color bold:NO]];
    return line;
}

#pragma mark - Overlays

// 2 x 5 pt ticks on the top edge, one per clip run (one per pixel at most)
- (void)drawClipMarkersInContext:(CGContextRef)context rect:(CGRect)rect {
    const WaveformData& data = *self.waveformData;
    const double totalFrames = data.duration * data.sampleRate;
    if (data.clipRunFrames.empty() || totalFrames <= 0) return;

    const CGFloat scale = [self backingScale];
    CGContextSaveGState(context);
    [p3(kOverlayAlert, _clipMarkerOpacity) setFill];
    long lastPixel = -1;
    for (uint64_t frame : data.clipRunFrames) {
        const double across = _zoom.acrossOf(frame / totalFrames);
        if (across < 0.0 || across > 1.0) continue;
        const CGFloat x = rect.origin.x + rect.size.width * across;
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
    [self drawBarInContext:context rect:rect];
    if (_zoom.zoomed()) [self drawZoomButtonInContext:context rect:rect];
    const int summary = [self summaryShown];
    if (summary == SummaryAlways || (summary == SummaryOnHover && _hovering)) {
        [self drawSummaryInContext:context rect:rect];
    }
    if ([self readoutShown] && _hovering && _readout.count > 0 && _hoverX < CGRectGetMaxX(rect) &&
        ![self isOverZoomButton] && ![self isOverBar]) {
        [self drawReadoutInContext:context rect:rect];
    }
}

// Where the bottom row's badges end on the right: the waveform's edge, or
// the bar while it shows
- (CGFloat)badgeRowRightFor:(CGRect)wave {
    CGRect box;
    [self barSegmentsFor:wave box:&box];
    return CGRectIsNull(box) ? CGRectGetMaxX(wave) : box.origin.x;
}

// Reset zoom, at the bottom right of the waveform while zoomed in (left of
// the bar); the summary badge moves to its left. Null when the
// waveform is too narrow.
- (NSAttributedString *)zoomButtonLabelHighlighted:(BOOL)highlighted {
    return [self text:@"Reset zoom" color:highlighted ? kOverlayValue : kOverlayLabel bold:NO];
}

- (CGRect)zoomButtonRectFor:(CGRect)wave {
    if (!_zoom.zoomed()) return CGRectNull;
    const NSSize size = [self zoomButtonLabelHighlighted:NO].size;
    const CGFloat w = std::ceil(size.width + 2 * TS(kBadgePadX));
    const CGFloat h = std::ceil(size.height + 2 * TS(kBadgePadY));
    const CGRect box = CGRectMake(std::round([self badgeRowRightFor:wave] - kBadgeInset - w), wave.origin.y + kBadgeInset, w, h);
    return box.origin.x < wave.origin.x ? CGRectNull : box;
}

- (BOOL)isOverZoomButton {
    return _hovering && CGRectContainsPoint([self zoomButtonRectFor:[self waveformRect]], CGPointMake(_hoverX, _hoverY));
}

- (void)drawZoomButtonInContext:(CGContextRef)context rect:(CGRect)rect {
    const CGRect box = [self zoomButtonRectFor:rect];
    if (CGRectIsNull(box)) return;
    [self fillOverlayBox:box radius:kBadgeRadius context:context];
    [[self zoomButtonLabelHighlighted:[self isOverZoomButton]]
        drawAtPoint:NSMakePoint(box.origin.x + TS(kBadgePadX), box.origin.y + TS(kBadgePadY))];
}

- (void)fillOverlayBox:(CGRect)box radius:(CGFloat)radius context:(CGContextRef)context {
    CGContextSaveGState(context);
    const CGRect inner = CGRectInset(box, 0.5, 0.5);
    CGPathRef shape = CGPathCreateWithRoundedRect(inner, radius, radius, NULL);
    [p3(kOverlayBackground, kOverlayBackgroundAlpha) setFill];
    CGContextAddPath(context, shape);
    CGContextFillPath(context);
    [p3(kOverlayBorder) setStroke];
    CGContextSetLineWidth(context, 1.0);
    CGContextAddPath(context, shape);
    CGContextStrokePath(context);
    CGPathRelease(shape);
    CGContextRestoreGState(context);
}

- (NSAttributedString *)text:(NSString *)s color:(uint32_t)color bold:(BOOL)bold {
    return [[NSAttributedString alloc] initWithString:s attributes:@{
        NSFontAttributeName: bold ? _overlayBoldFont : _overlayFont,
        NSForegroundColorAttributeName: p3(color)
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
    // With phrase markers: the grid and how much of it holds
    if (_phraseMarkers && _phraseGrid && !_phrases.empty()) {
        add(@"  Grid ", kOverlayLabel);
        add(str(overlay::formatNumber(_phraseGrid->summary.bpm, 2)), kOverlayValue);
        add(@" BPM · ", kOverlayLabel);
        if (_phraseFollowGrid && _phraseGrid->hasSections()) {
            add([NSString stringWithFormat:@"%zu", _phraseGrid->sections.size()], kOverlayValue);
            add(@" grids · ", kOverlayLabel);
        }
        add([NSString stringWithFormat:@"%ld%%", std::lround(waveseek::lockedPhraseShare(_phrases) * 100.0)], kOverlayValue);
        add(@" locked", kOverlayLabel);
    }

    const NSSize size = line.size;
    const CGRect zoomButton = [self zoomButtonRectFor:rect];
    const CGFloat right = CGRectIsNull(zoomButton) ? [self badgeRowRightFor:rect] : zoomButton.origin.x;
    const CGRect box = CGRectMake(std::round(right - kBadgeInset - size.width - 2 * TS(kBadgePadX)),
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

    // The masks' column under the mouse; none beyond the track's ends
    const analysis::Columns& r = _readout;
    const long column = (long)std::floor((mouseX - rect.origin.x) * scale) - _maskOffsetPx;
    if (column < 0 || column >= (long)r.count) return;
    const size_t c = (size_t)column;
    const double seconds = _zoom.positionAt((mouseX - rect.origin.x) / std::max<CGFloat>(1.0, rect.size.width))
                         * self.trackDuration;

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
        if ([self summaryShown] != SummaryOff || _zoom.zoomed() || [self barShown]) {   // the badges' row
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
    // Near a phrase marker: its line under the time, the rows below it
    NSAttributedString *phraseLine = [self phraseLineNear:mouseX];
    const CGFloat extra = phraseLine ? TS(kReadoutRowStep) : 0.0;
    const bool bands = TS(kReadoutHeight) + extra <= room;
    // Without the bands, as many value rows as fit (Corr goes first); in a
    // view too short even for the time, no box
    int rowCount = 4;
    auto compactHeight = [&](int rows) {
        return TS(rows > 0 ? kReadoutCompactHeight - (4 - rows) * kReadoutRowStep : kReadoutRowsY) + extra;
    };
    while (!bands && rowCount > 0 && compactHeight(rowCount) > room) --rowCount;
    const CGFloat height = bands ? TS(kReadoutHeight) + extra : compactHeight(rowCount);
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
    // Thinned markers say how far apart they are instead of the seek hint
    NSString *hint = phraseLine && _phraseBeatsDrawn != _phraseLength
        ? [NSString stringWithFormat:@"every %d beats", _phraseBeatsDrawn] : @"click to seek";
    drawRight([self text:hint color:kOverlayLabel bold:NO], TS(kReadoutHeaderY));
    if (phraseLine) drawLeft(phraseLine, TS(kReadoutRowsY));

    struct Row { NSString *label; std::string value; NSString *unit; };
    const Row rows[4] = {
        { @"LUFS-S", overlay::formatNumber(r.lufs[c], 1), @"" },
        { @"Peak", overlay::formatNumber(r.peakDb[c], 1), @" dBFS" },
        { @"Crest", overlay::formatNumber(r.crestDb[c], 1), @" dB" },
        { @"Corr", overlay::formatNumber(r.correlation[c], 2, true), @"" },
    };
    for (int i = 0; i < rowCount; ++i) {
        const CGFloat y = TS(kReadoutRowsY) + i * TS(kReadoutRowStep) + extra;
        drawLeft([self text:rows[i].label color:kOverlayLabel bold:NO], y);
        drawRight([self text:[str(rows[i].value) stringByAppendingString:rows[i].unit] color:kOverlayValue bold:NO], y);
    }

    if (!bands) return;

    // Lo / Mid / Hi: stacked bar, then the shares
    const CGRect bar = CGRectMake(left + TS(kReadoutPadX), top - TS(kReadoutBarY) - extra - TS(kReadoutBarHeight),
                                  width - 2 * TS(kReadoutPadX), TS(kReadoutBarHeight));
    CGContextSaveGState(context);
    [p3(kOverlayBorder) setFill];
    CGContextFillRect(context, bar);
    int percent[3] = { 0, 0, 0 };
    const bool known = !std::isnan(r.bandShare[0][c]);
    if (known) {
        CGFloat x = bar.origin.x;
        for (int b = 0; b < 3; ++b) {
            const CGFloat w = bar.size.width * r.bandShare[b][c];
            [p3(kBandColors[b]) setFill];
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
    drawLeft(band(@"Lo", 0, @""), TS(kReadoutBandsY) + extra);
    drawCentre(band(@"Mid", 1, @""), TS(kReadoutBandsY) + extra);
    drawRight(band(@"Hi", 2, @" %"), TS(kReadoutBandsY) + extra);
}

#pragma mark - Scales

- (NSAttributedString *)scaleText:(NSString *)s {
    return [[NSAttributedString alloc] initWithString:s attributes:@{
        NSFontAttributeName: _overlayFont,
        NSForegroundColorAttributeName: p3(kScaleLabel)
    }];
}

// Strip under the waveform: border, major ticks with m:ss labels, minor
// ticks at a quarter of the major interval
- (void)drawRulerInContext:(CGContextRef)context wave:(CGRect)wave {
    const CGFloat scale = [self backingScale];
    const CGFloat top = self.bounds.origin.y + [self rulerHeight];
    CGContextSaveGState(context);

    [p3(kScaleBorder) setStroke];
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
    // The part of the track in view; ticks stay on whole multiples of the
    // interval when zoomed in
    const double first = _zoom.start * duration, shown = _zoom.span() * duration;
    auto xAt = [&](double seconds) { return wave.origin.x + wave.size.width * ((seconds - first) / shown); };
    const double major = overlay::rulerInterval(shown, wave.size.width, _zoom.zoomed());
    const double minor = major / 4.0;
    [p3(kScaleLabel, 0.6) setStroke];
    // Within the track: a centred view shows space beyond its ends
    const double last = std::min(first + shown, duration);
    for (long i = std::max(0L, (long)std::ceil(first / minor - 1e-9)); i * minor <= last; ++i) {
        const CGFloat x = (std::floor(xAt(i * minor) * scale) + 0.5) / scale;
        const CGFloat length = (i % 4 == 0) ? kRulerMajorTick : kRulerMinorTick;
        CGContextMoveToPoint(context, x, top);
        CGContextAddLineToPoint(context, x, top - length);
    }
    CGContextStrokePath(context);

    for (long i = std::max(0L, (long)std::ceil(first / major - 1e-9)); i * major <= last; ++i) {
        NSAttributedString *label = [self scaleText:str(overlay::formatClock(i * major))];
        const CGFloat x = xAt(i * major) + TS(kRulerLabelGap);
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

#pragma mark - Bottom Bar

// Every beat of the grid shown (following a new grid when the markers do);
// a new list ends the loop, whose beats were the old one's
- (const std::vector<double> &)beats {
    if (_beatsFor != _phraseGrid || _beatsFollow != _phraseFollowGrid || _beatsDuration != self.trackDuration) {
        _beats = _phraseGrid ? waveseek::beatTimes(*_phraseGrid, self.trackDuration, _phraseFollowGrid)
                             : std::vector<double>();
        _beatsFor = _phraseGrid;
        _beatsFollow = _phraseFollowGrid;
        _beatsDuration = self.trackDuration;
        [self endLoop];
    }
    return _beats;
}

- (BOOL)hasTrackShown {
    return self.waveformData && self.waveformData->isValid() && self.trackDuration > 0.0;
}

// The mixer is chosen and the track's beats are in
- (BOOL)mixerReady {
    return _controlsMode == waveform_config::ControlsMixer && [self hasTrackShown] && [self beats].size() >= 2;
}

// The loudness summary and the readout show with the analytics controls,
// as the preferences set them
- (int)summaryShown {
    return _controlsMode == waveform_config::ControlsAnalytics ? _summaryMode : waveform_config::SummaryOff;
}

- (BOOL)readoutShown {
    return _controlsMode == waveform_config::ControlsAnalytics && _showReadout;
}

// On hover, and while one of its menus is open
- (BOOL)barShown {
    return (_hovering || _barMenuOpen) && [self hasTrackShown];
}

- (NSImage *)barIcon:(NSString *)name color:(uint32_t)color {
    if (!_barIcons) _barIcons = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@/%06X", name, color];
    NSImage *icon = _barIcons[key];
    if (icon) return icon;
    NSImage *symbol = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!symbol) return nil;
    NSImageSymbolConfiguration *config =
        [[NSImageSymbolConfiguration configurationWithPointSize:TS(kBarIconSize) weight:NSFontWeightRegular]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[ p3(color) ]]];
    icon = [symbol imageWithSymbolConfiguration:config];
    if (icon) _barIcons[key] = icon;
    return icon;
}

// The bar at the bottom right of the waveform, while it shows: the cog,
// with the mixer's jumps and loop to its left (the cog alone when those
// don't fit). `box` gets the box around them, null when none.
- (std::vector<BarSegment>)barSegmentsFor:(CGRect)wave box:(CGRect *)box {
    if (box) *box = CGRectNull;
    if (![self barShown]) return {};
    NSDictionary *attributes = @{ NSFontAttributeName: _overlayFont };
    const CGFloat height = std::ceil([@"I" sizeWithAttributes:attributes].height + 2 * TS(kBadgePadY));
    const CGFloat bottom = wave.origin.y + kBadgeInset;
    NSImage *cog = [self barIcon:@"gearshape" color:kOverlayLabel];

    auto layout = [&](bool mixer, CGRect *outBox) {
        std::vector<BarSegment> segments;
        if (mixer) {
            NSString *size = [NSString stringWithFormat:@"%d▾", _beatSize];
            segments = {
                { BarControlBack32, @"‹32" }, { BarControlBack16, @"‹16" }, { BarControlBackSize, @"‹" },
                { BarControlSizeMenu, size }, { BarControlForwardSize, @"›" }, { BarControlForward16, @"16›" },
                { BarControlForward32, @"32›" },
                { BarControlLoop, @"Loop", true },
            };
        }
        segments.push_back({ BarControlCog, cog ? nil : @"Controls", mixer });
        CGFloat total = 0.0;
        for (BarSegment &s : segments) {
            const CGFloat content = s.title ? [s.title sizeWithAttributes:attributes].width : cog.size.width;
            s.rect.size = CGSizeMake(std::ceil(content + 2 * TS(kBarSegmentPadX)), height);
            total += s.rect.size.width + (s.groupStart ? TS(kBarGroupGap) : 0.0);
        }
        CGFloat x = std::round(CGRectGetMaxX(wave) - kBadgeInset - total);
        *outBox = CGRectMake(x, bottom, total, height);
        for (BarSegment &s : segments) {
            if (s.groupStart) x += TS(kBarGroupGap);
            s.rect.origin = CGPointMake(x, bottom);
            x += s.rect.size.width;
        }
        return segments;
    };

    CGRect frame;
    const bool mixer = [self mixerReady];
    std::vector<BarSegment> segments = layout(mixer, &frame);
    if (frame.origin.x < wave.origin.x + kBadgeInset && mixer) segments = layout(false, &frame);
    if (frame.origin.x < wave.origin.x + kBadgeInset || CGRectGetMaxY(frame) > CGRectGetMaxY(wave)) return {};
    if (box) *box = frame;
    return segments;
}

- (BOOL)isOverBar {
    CGRect box;
    [self barSegmentsFor:[self waveformRect] box:&box];
    return _hovering && CGRectContainsPoint(box, CGPointMake(_hoverX, _hoverY));
}

- (void)drawBarInContext:(CGContextRef)context rect:(CGRect)rect {
    CGRect box;
    const std::vector<BarSegment> segments = [self barSegmentsFor:rect box:&box];
    if (segments.empty()) return;
    [self fillOverlayBox:box radius:kBadgeRadius context:context];
    const CGFloat scale = [self backingScale];
    const CGPoint mouse = CGPointMake(_hoverX, _hoverY);
    CGContextSaveGState(context);
    for (const BarSegment &s : segments) {
        if (s.groupStart) {
            const CGFloat x = std::round((s.rect.origin.x - TS(kBarGroupGap) / 2) * scale) / scale;
            [p3(kOverlayBorder) setFill];
            CGContextFillRect(context, CGRectMake(x, s.rect.origin.y + 4.0, 1.0 / scale, s.rect.size.height - 8.0));
        }
        const bool hot = (_hovering && CGRectContainsPoint(s.rect, mouse)) || (s.control == BarControlCog && _barMenuOpen);
        const bool looping = s.control == BarControlLoop && _loop.active();
        const uint32_t color = looping ? kLoopColor : hot ? kOverlayValue : kOverlayLabel;
        if (!s.title) {
            NSImage *icon = [self barIcon:@"gearshape" color:color];
            const NSSize size = icon.size;
            [icon drawInRect:NSMakeRect(std::round(CGRectGetMidX(s.rect) - size.width / 2),
                                        std::round(CGRectGetMidY(s.rect) - size.height / 2), size.width, size.height)];
        } else {
            NSAttributedString *label = [self text:s.title color:color bold:looping];
            [label drawAtPoint:NSMakePoint(std::round(CGRectGetMidX(s.rect) - label.size.width / 2),
                                           s.rect.origin.y + TS(kBadgePadY))];
        }
    }
    CGContextRestoreGState(context);
}

// The cog's menu: the controls, and how a zoomed view follows the cursor
- (void)showControlsMenuFor:(const BarSegment &)segment {
    using namespace waveform_config;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Controls"];
    menu.autoenablesItems = NO;
    auto add = [&](NSString *title, SEL action, NSInteger tag, bool on, bool enabled) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
        item.target = self;
        item.tag = tag;
        item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        item.enabled = enabled;
        [menu addItem:item];
    };
    auto header = [&](NSString *title) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        item.enabled = NO;
        [menu addItem:item];
    };
    header(@"Controls");
    add(@"No Controls", @selector(controlsModeChosen:), ControlsNone, _controlsMode == ControlsNone, true);
    add(_haveBeatGrids ? @"Mixer: Beat Jumps and Loops" : @"Mixer: Needs BPM Analyzer", @selector(controlsModeChosen:),
        ControlsMixer, _controlsMode == ControlsMixer, _haveBeatGrids);
    add(@"Analytics: Loudness and Readout", @selector(controlsModeChosen:), ControlsAnalytics,
        _controlsMode == ControlsAnalytics, true);
    [menu addItem:[NSMenuItem separatorItem]];
    header(@"Zoomed In");
    add(@"Don't Follow the Cursor", @selector(followModeChosen:), FollowNone, _followMode == FollowNone, _zoomEnabled);
    add(@"Follow the Cursor", @selector(followModeChosen:), FollowCursor, _followMode == FollowCursor, _zoomEnabled);
    add(@"Keep the Cursor Centred", @selector(followModeChosen:), FollowCentre, _followMode == FollowCentre, _zoomEnabled);
    _barMenuOpen = YES;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(segment.rect.origin.x, CGRectGetMaxY(segment.rect))
                            inView:self];
    _barMenuOpen = NO;
    [self setNeedsDisplay:YES];
}

// Saved and sent to every seekbar and the preferences; the controller
// fetches the beat grid for the mixer
- (void)controlsModeChosen:(NSMenuItem *)item {
    waveform_config::setConfigInt(waveform_config::kKeyControlsMode, item.tag);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"WaveformSeekbarSettingsChanged" object:nil];
}

- (void)followModeChosen:(NSMenuItem *)item {
    waveform_config::setConfigInt(waveform_config::kKeyZoomFollow, item.tag);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"WaveformSeekbarSettingsChanged" object:nil];
}

// The loop's range in the loop colour, edges and a light fill
- (void)drawLoopInContext:(CGContextRef)context rect:(CGRect)rect {
    if (!_loop.active() || !(self.trackDuration > 0.0)) return;
    const waveseek::BeatLoop &shown = _loopDragging ? _loopDragPreview : _loop;   // where a drag would put it
    const double a = _zoom.acrossOf(shown.start / self.trackDuration);
    const double b = _zoom.acrossOf(shown.end / self.trackDuration);
    if (b <= 0.0 || a >= 1.0) return;
    const CGFloat scale = [self backingScale];
    auto xAt = [&](double across) { return std::round((rect.origin.x + rect.size.width * across) * scale) / scale; };
    const CGFloat left = xAt(std::max(0.0, a));
    const CGFloat right = std::max(left + 1.0 / scale, xAt(std::min(1.0, b)));
    CGContextSaveGState(context);
    [p3(kLoopColor, 0.18) setFill];
    CGContextFillRect(context, CGRectMake(left, rect.origin.y, right - left, rect.size.height));
    [p3(kLoopColor, 0.9) setFill];
    if (a >= 0.0) CGContextFillRect(context, CGRectMake(left, rect.origin.y, 1.0, rect.size.height));
    if (b <= 1.0) CGContextFillRect(context, CGRectMake(right - 1.0, rect.origin.y, 1.0, rect.size.height));
    CGContextRestoreGState(context);
}

// `seconds`, the playback position just read, or where a seek just sent
// will put it while the position doesn't show that yet
- (double)settledPosition:(double)seconds {
    if (std::isnan(_pendingSeek)) return seconds;
    const double elapsed = CFAbsoluteTimeGetCurrent() - _pendingSince;
    const double expected = _pendingSeek + (self.playing ? elapsed : 0.0);
    if (std::fabs(seconds - expected) < kSeekLanded || elapsed > kSeekTimeout) {
        _pendingSeek = NAN;
        return seconds;
    }
    return expected;
}

// The audible position: foobar2000's, mapped through the loop DSP's timeline
// while it changes what plays
- (double)currentSeconds {
    double seconds = self.playbackPosition * self.trackDuration;
    if ([self.delegate respondsToSelector:@selector(waveformSeekbarViewPlaybackTime:)]) {
        const double read = [self.delegate waveformSeekbarViewPlaybackTime:self];
        if (std::isfinite(read)) seconds = [self displayedTimeFor:read];
    }
    return [self settledPosition:seconds];
}

- (void)seekTo:(double)seconds {
    _pendingSeek = seconds;
    _pendingSince = CFAbsoluteTimeGetCurrent();
    [self performSeekToTime:seconds];
    if (self.trackDuration > 0.0) self.playbackPosition = seconds / self.trackDuration;
    [self setNeedsDisplay:YES];
}

- (void)setLoop:(const waveseek::BeatLoop &)loop {
    _loop = loop;
    ++_loopGeneration;          // a seek scheduled for the old one is dropped
    _loopEndScheduled = false;
    [self updateLowLatency];
    [self setNeedsDisplay:YES];
}

// Off; with the loop DSP, playback goes on from where it is
- (void)endLoop {
    if (!_loop.active()) return;
    if ([self deckMode]) {
        waveseek::LoopAction exit;
        exit.kind = waveseek::LoopAction::Exit;
        beatloop::act(exit);
    }
    [self setLoop:waveseek::BeatLoop()];
}

#pragma mark - Loop DSP

// The mixer plays through the loop DSP when it is running
- (BOOL)deckMode {
    return _controlsMode == waveform_config::ControlsMixer && beatloop::running();
}

// It knows the track time of what it plays and no seek of ours is on its way
- (BOOL)deckReady {
    return [self deckMode] && _deck.synced && _deckEpoch != 0 && _deck.epoch == _deckEpoch && _armId == 0;
}

// It holds the track's audio over from .. to (to may be NAN: not needed)
- (BOOL)deckHolds:(double)from to:(double)to {
    return [self deckReady] && from >= _deck.bufferedFrom + kDeckMargin &&
           (std::isnan(to) || to <= _deck.bufferedTo - kDeckMargin);
}

// A seek of our own: it gives the DSP the track time, then `then` applies
- (void)armedSeekTo:(double)target then:(const waveseek::LoopAction *)then {
    _armId = beatloop::armSeek(target, then);
    _armAt = CFAbsoluteTimeGetCurrent();
    _loopCheckAfter = _armAt + 0.5;
    [self seekTo:target];
}

// A request to the DSP; when it is turned down, the seek instead
- (void)request:(waveseek::LoopAction)action orSeekTo:(double)target then:(const waveseek::LoopAction *)then {
    _requestId = beatloop::act(action);
    _fallbackTarget = target;
    _fallbackHasThen = then != nullptr;
    if (then) _fallbackThen = *then;
    _loopCheckAfter = CFAbsoluteTimeGetCurrent() + 0.5;
}

static waveseek::LoopAction makeAction(waveseek::LoopAction::Kind kind, double start, double end, double to) {
    waveseek::LoopAction a;
    a.kind = kind;
    a.start = start;
    a.end = end;
    a.to = to;
    return a;
}

// Playback to `target`: inside the DSP's audio a splice, else a seek
// The loop stays set: inside it playback loops, before it playback runs
// into it, past it playback plays on and the loop waits. The cursor follows
// the audio, so it moves when the jump is heard.
- (void)deckSeekTo:(double)target {
    [self deckSeekTo:target by:NAN onBeat:NO];
}

// `by` (relative to what plays when the DSP takes it, so the beat holds
// however late) or to `target`; onBeat: wait for the next beat of what
// plays, so the target beat lands on a beat. `target` also places the
// fallback seek and decides what the loop does.
- (void)deckSeekTo:(double)target by:(double)by onBeat:(BOOL)onBeat {
    using Kind = waveseek::LoopAction::Kind;
    waveseek::LoopAction jump = makeAction(Kind::Jump, 0, 0, target);
    jump.by = by;
    if (onBeat && std::isnan(by) && _phraseGrid) {
        const waveseek::GridAt grid = waveseek::gridAt(*_phraseGrid, [self currentSeconds], _phraseFollowGrid);
        if (grid.bpm > 0.0) {
            jump.beat = 60.0 / grid.bpm;
            jump.beatAnchor = grid.anchorSeconds;
        }
    }
    if (!_loop.active()) {
        if ([self deckHolds:target to:target]) [self request:jump orSeekTo:target then:nullptr];
        else [self armedSeekTo:target then:nullptr];
        return;
    }
    // The seek when the DSP does not hold the audio: inside the loop from
    // its start (playing on from the target once decoded), before it from
    // the target with the loop set ahead, past it just the target
    const bool inside = _loop.contains(target), before = target < _loop.start;
    const waveseek::LoopAction setLoop = makeAction(Kind::Loop, _loop.start, _loop.end, target);
    const double seekTarget = inside ? _loop.start : target;
    const waveseek::LoopAction *then = inside || before ? &setLoop : nullptr;
    if ([self deckHolds:target to:target]) {
        [self request:(_deck.looping || !then) ? jump : setLoop orSeekTo:seekTarget then:then];
    } else {
        [self armedSeekTo:seekTarget then:then];
    }
}

// The DSP's status, once per position check: our seek taken, a seek from
// elsewhere (the loop ends), the track time measured while untouched, a
// request turned down (seek instead), the DSP leaving a loop by itself
- (void)pollDeck:(double)seconds {
    if (![self deckMode]) {
        if (_deckEpoch != 0) {
            _deckEpoch = 0;
            beatloop::releaseClock();
        }
        return;
    }
    _deck = beatloop::status();
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_armId != 0) {
        if (_deck.boundArmId == _armId) {
            _armId = 0;
            _deckEpoch = _deck.epoch;
        } else if (now - _armAt > beatloop::kArmTimeout) {
            _armId = 0;
            FB2K_console_formatter() << "[WaveSeek] Beat loop: the loop DSP missed a seek";
        }
    }
    if (_armId == 0 && _deckEpoch != 0 && _deck.epoch != _deckEpoch) {   // a seek from elsewhere
        _deckEpoch = 0;
        _requestId = 0;   // the loop stays set; it is given to the DSP again below
    }
    if (_armId == 0 && _deck.synced) _deckEpoch = _deck.epoch;
    if (_armId == 0 && !_deck.synced && _deck.pristine && self.playing) [self measureTrackTime:seconds];
    if (_armId == 0 && _deck.synced && _deck.pristine && _deck.live && self.playing) [self measureClock:seconds];
    if (_requestId != 0 && _deck.rejectedId == _requestId) {
        _requestId = 0;
        if (!std::isnan(_fallbackTarget)) [self armedSeekTo:_fallbackTarget then:_fallbackHasThen ? &_fallbackThen : nullptr];
    } else if (_requestId != 0 && _deck.lastActionId >= _requestId) {
        if (_deck.lastTakenId == _requestId) {
            FB2K_console_formatter() << "[WaveSeek] Mixer: request taken by the DSP after "
                                     << pfc::format_int(std::lround(_deck.lastTakenMs)) << " ms; playback runs "
                                     << pfc::format_int(std::lround(_measuredLag * 1000.0)) << " ms behind the DSP";
        }
        _requestId = 0;
    }
    // The loop set, the DSP without it (a seek from elsewhere, or it ran too
    // far ahead) and playback before it: set it in the DSP again, ahead, so
    // it catches playback (once a second at most when turned down)
    if (_loop.active() && [self deckReady] && !_deck.looping && _requestId == 0 && now > _loopCheckAfter &&
        now - _loopRearmAt > 1.0 && [self displayedTimeFor:seconds] < _loop.start) {
        _loopRearmAt = now;
        [self request:makeAction(waveseek::LoopAction::Loop, _loop.start, _loop.end, NAN) orSeekTo:NAN then:nullptr];
    }
    [self noteTimingAt:now seconds:seconds];
    if (_latencyNoteAt > 0 && now >= _latencyNoteAt && [self deckReady]) {
        _latencyNoteAt = 0;
        const double played = beatloop::playedSinceSeek();
        static bool noted = false;
        if (std::isfinite(played) && !noted) {
            noted = true;
            FB2K_console_formatter() << "[WaveSeek] Beat loop: a change is heard about "
                                     << pfc::format_float(std::max(0.0, _deck.outSeconds - played), 0, 2)
                                     << " s after it is made (the output buffer; Preferences > Playback > Output)";
        }
    }
}

// Untouched audio: foobar2000's position less the audio played since the
// seek is the seek's target, the track time of the DSP's first frame
- (void)measureTrackTime:(double)seconds {
    const double played = beatloop::playedSinceSeek();
    if (!std::isfinite(played) || !std::isfinite(seconds)) return;
    if (_syncEpoch != _deck.epoch) {
        _syncEpoch = _deck.epoch;
        _syncSamples.clear();
    }
    _syncSamples.push_back(seconds - played);
    if (_syncSamples.size() > 12) _syncSamples.erase(_syncSamples.begin());
    if (_syncSamples.size() < 5) return;
    std::vector<double> sorted(_syncSamples.end() - 5, _syncSamples.end());
    std::sort(sorted.begin(), sorted.end());
    if (sorted.back() - sorted.front() > 0.01) return;   // still settling
    double t0 = sorted[2];
    if (std::fabs(t0) < 0.02) t0 = 0.0;                 // from the track's start
    beatloop::sync(_deck.epoch, t0);
    _syncSamples.clear();
}

// Untouched audio: foobar2000's position is what is heard, so the
// visualisation clock less (position - the seek's track time) is how far
// the clock runs ahead of the audio (if it does not count the output buffer)
- (void)measureClock:(double)seconds {
    const double played = beatloop::playedSinceSeek();
    if (!std::isfinite(played) || !std::isfinite(seconds)) return;
    _clockSamples.push_back(played - (seconds - _deck.startTime));
    if (_clockSamples.size() > 9) _clockSamples.erase(_clockSamples.begin());
    if (_clockSamples.size() < 5) return;
    std::vector<double> sorted(_clockSamples);
    std::sort(sorted.begin(), sorted.end());
    _clockOffset = sorted[sorted.size() / 2];
}

// The track time playing: through the DSP's timeline while it changes what
// plays, else foobar2000's position
- (double)displayedTimeFor:(double)seconds {
    if (![self deckMode] || _deckEpoch == 0 || _deck.epoch != _deckEpoch || !_deck.synced || _deck.pristine) {
        return seconds;
    }
    const double played = beatloop::playedSinceSeek();
    if (!std::isfinite(played)) return seconds;
    const double t = waveseek::trackTimeAt(_deck.timeline, std::max(0.0, played - _clockOffset));
    return std::isfinite(t) ? t : seconds;
}

// While a change may come (the mouse over the seekbar, a menu or a drag),
// short steps from the DSP and foobar2000's low-latency hint
- (void)updateLowLatency {
    const bool on = [self deckMode] && (_hovering || _barMenuOpen || _loopDragging);
    if (on == _lowLatency) return;
    _lowLatency = on;
    beatloop::setLowLatency(on);
}

#pragma mark - Mixer Actions

- (void)performBarControl:(const BarSegment &)segment {
    // Option with a jump while looping moves the whole loop
    const bool option = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
    _jumpMovesLoop = option;
    switch (segment.control) {
        case BarControlCog: [self showControlsMenuFor:segment]; break;
        case BarControlBack32: [self jumpBeats:-32]; break;
        case BarControlBack16: [self jumpBeats:-16]; break;
        case BarControlBackSize: [self jumpBeats:-_beatSize]; break;
        case BarControlForwardSize: [self jumpBeats:_beatSize]; break;
        case BarControlForward16: [self jumpBeats:16]; break;
        case BarControlForward32: [self jumpBeats:32]; break;
        case BarControlLoop: [self toggleLoop]; break;
        case BarControlSizeMenu: [self showSizeMenuFor:segment]; break;
        case BarControlNone: break;
    }
    [self setNeedsDisplay:YES];
}

// The loop moved by `count` beats, playback at the same place in it
- (void)moveLoopBy:(int)count {
    const std::vector<double> &beats = [self beats];
    const waveseek::BeatLoop moved = waveseek::movedLoop(beats, _loop, count, self.trackDuration);
    if (!moved.active() || count == 0) return;
    const double now = [self currentSeconds];
    // Playback elsewhere (the loop waiting): only the loop moves
    if (!_loop.contains(now)) {
        [self setLoop:moved];
        if ([self deckReady]) {
            [self request:makeAction(waveseek::LoopAction::Loop, moved.start, moved.end, NAN) orSeekTo:NAN then:nullptr];
        }
        return;
    }
    const double shifted = waveseek::timeAtBeat(beats, waveseek::beatPosition(beats, now) + count);
    const double target = moved.contains(shifted) ? shifted : waveseek::wrappedIntoLoop(moved, shifted);
    if ([self deckMode]) {
        const waveseek::LoopAction then = makeAction(waveseek::LoopAction::Loop, moved.start, moved.end, target);
        const double delta = moved.start - _loop.start;
        if ([self deckHolds:moved.start to:NAN] && _deck.looping &&
            _deck.bufferedTo - kDeckMargin >= std::max(moved.start, now + delta)) {
            [self request:makeAction(waveseek::LoopAction::Move, moved.start, moved.end, NAN) orSeekTo:moved.start
                     then:&then];
        } else {
            [self armedSeekTo:moved.start then:&then];
        }
        [self setLoop:moved];
        return;
    }
    [self setLoop:moved];
    [self seekTo:target];
}

// `count` beats on or back, at the same place in the beat. While looping,
// with Option the whole loop moves (nothing happens when it would leave the
// track); without, playback jumps and the loop stays set (see deckSeekTo:).
- (void)jumpBeats:(int)count {
    if (_loop.active() && _jumpMovesLoop) {
        [self moveLoopBy:count];
        return;
    }
    const double now = [self currentSeconds];
    const double target = waveseek::jumpTarget([self beats], now, count, self.trackDuration);
    if (std::isnan(target)) return;
    if ([self deckMode]) {
        [self deckSeekTo:target by:target - now onBeat:NO];   // relative: the beat holds
        return;
    }
    [self seekTo:target];
}

// Where the 16-beat phrases (and new grids) start, for a loop to catch
- (std::vector<double>)phraseStartTimes {
    std::vector<double> out;
    if (!_phraseGrid) return out;
    for (const waveseek::PhraseMarker &m : waveseek::phraseMarkers(*_phraseGrid, 16, _phraseFollowGrid)) {
        out.push_back(m.seconds);
    }
    return out;
}

// A loop of the chosen length from the beat behind the cursor (or a phrase
// start near it), playing from its start; or off
- (void)toggleLoop {
    if (_loop.active()) {
        [self endLoop];
        return;
    }
    const double now = [self currentSeconds];
    const waveseek::BeatLoop loop = waveseek::makeLoop([self beats], now, _beatSize, self.trackDuration,
                                                       [self phraseStartTimes]);
    if (!loop.active()) return;
    [self setLoop:loop];
    if ([self deckMode]) {
        // Set around what plays, no jump: it wraps at its end, on the beat
        // (past its end already: into it as far as its length goes; a phrase
        // start just ahead: plays into it)
        waveseek::LoopAction around = makeAction(waveseek::LoopAction::Loop, loop.start, loop.end, NAN);
        around.keepPhase = true;
        const waveseek::LoopAction then = makeAction(waveseek::LoopAction::Loop, loop.start, loop.end, loop.start);
        if ([self deckHolds:loop.start to:NAN]) {
            [self request:around orSeekTo:loop.start then:&then];
        } else {
            [self armedSeekTo:loop.start then:&then];
        }
        if (_latencyNoteAt == 0) _latencyNoteAt = CFAbsoluteTimeGetCurrent() + 1.0;
        return;
    }
    [self seekTo:loop.start];
}

- (void)showSizeMenuFor:(const BarSegment &)segment {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Loop and jump size"];
    for (int beats : waveseek::kBeatSizeChoices) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"%d %@", beats, beats == 1 ? @"beat" : @"beats"]
                   action:@selector(sizeChosen:) keyEquivalent:@""];
        item.target = self;
        item.tag = beats;
        item.state = beats == _beatSize ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
    _barMenuOpen = YES;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(segment.rect.origin.x, CGRectGetMaxY(segment.rect))
                            inView:self];
    _barMenuOpen = NO;
    [self setNeedsDisplay:YES];
}

// The new size for the jumps beside the menu and the loop. A loop playing
// keeps its start and takes the new length at once: playback past its new
// end goes back into it, as far in as it was past a multiple of the length.
- (void)sizeChosen:(NSMenuItem *)item {
    _beatSize = (int)item.tag;
    waveform_config::setConfigInt(waveform_config::kKeyBeatSize, _beatSize);
    if (_loop.active()) {
        const waveseek::BeatLoop resized = waveseek::resizedLoop([self beats], _loop, _beatSize, self.trackDuration);
        if (resized.active()) {
            const double now = [self currentSeconds];
            const bool playing = _loop.contains(now);   // playback in the loop, not elsewhere with it waiting
            const double into = resized.contains(now) ? now : waveseek::wrappedIntoLoop(resized, now);
            [self setLoop:resized];
            if ([self deckMode]) {
                const waveseek::LoopAction then = makeAction(waveseek::LoopAction::Loop, resized.start, resized.end, into);
                if ([self deckReady] && _deck.looping) {
                    [self request:makeAction(waveseek::LoopAction::Resize, resized.start, resized.end, NAN)
                         orSeekTo:playing ? resized.start : NAN then:&then];
                } else if (playing) {
                    [self armedSeekTo:resized.start then:&then];
                }
            } else if (playing && !resized.contains(now)) {
                [self seekTo:into];
            }
        }
    }
    [self setNeedsDisplay:YES];
}

// The loop by seeking, at the position checks: without the loop DSP, or
// with it when it does not hold the loop and playback is inside (after a
// seek from elsewhere into it; the seek to its start then gives it the loop)
- (void)followLoopAt:(double)seconds {
    [self pollDeck:seconds];
    [self updateLowLatency];
    const double position = [self displayedTimeFor:seconds];
    const bool wasInside = _wasInsideLoop;
    _wasInsideLoop = _loop.active() && _loop.contains(position);
    if (!_loop.active()) return;
    if ([self deckMode] && (_deck.looping || _armId != 0 || _requestId != 0)) return;   // the DSP has it
    const waveseek::LoopStep step = waveseek::loopStep(_loop, [self settledPosition:position], kLoopLookahead, wasInside);
    switch (step.kind) {
        case waveseek::LoopStep::None:
            break;
        case waveseek::LoopStep::Seek:     // late: as far in as it overran, so the beat holds
            if ([self deckMode]) [self seekToLoopStartArmed];
            else [self seekTo:step.value];
            break;
        case waveseek::LoopStep::Schedule: {
            if (_loopEndScheduled) break;
            _loopEndScheduled = true;
            const unsigned generation = _loopGeneration;
            __weak WaveformSeekbarView *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(step.value * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WaveformSeekbarView *me = weakSelf;
                if (!me || me->_loopGeneration != generation) return;
                me->_loopEndScheduled = false;
                if (!me->_loop.active() || !me.playing) return;
                if (![me deckMode]) [me seekTo:me->_loop.start];
                else if (!me->_deck.looping && me->_armId == 0) [me seekToLoopStartArmed];
            });
            break;
        }
    }
}

// To the loop's start, giving the loop DSP the loop there
- (void)seekToLoopStartArmed {
    const waveseek::LoopAction then = makeAction(waveseek::LoopAction::Loop, _loop.start, _loop.end, _loop.start);
    [self armedSeekTo:_loop.start then:&then];
}

// How far playback runs behind what the DSP takes in, measured while the
// audio is untouched and passes through (foobar2000's position is then
// what is heard); every 10 s while the mixer is on, the console line with
// it, foobar2000's block size and the output buffer
- (void)noteTimingAt:(CFAbsoluteTime)now seconds:(double)seconds {
    if (![self deckReady] || !self.playing) return;
    if (_deck.live && _deck.pristine && std::isfinite(seconds)) {
        const double lag = _deck.bufferedTo - seconds;
        _measuredLag = _measuredLag > 0.0 ? 0.8 * _measuredLag + 0.2 * lag : lag;
    }
    if (now < _timingNoteAt) return;
    _timingNoteAt = now + 10.0;
    FB2K_console_formatter() << "[WaveSeek] Mixer timing: blocks of "
                             << pfc::format_int(std::lround(_deck.blockSeconds * 1000.0)) << " ms, playback "
                             << pfc::format_int(std::lround(_measuredLag * 1000.0)) << " ms behind the DSP, output buffer "
                             << pfc::format_int(beatloop::outputBufferMs()) << " ms, "
                             << pfc::format_float(_deck.ahead, 0, 2) << " s decoded ahead"
                             << (_lowLatency ? ", short steps" : "");
}

#pragma mark - Mouse Events

- (void)trackHoverWithEvent:(NSEvent *)event {
    _hovering = YES;
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    _hoverX = p.x;
    _hoverY = p.y;
}

- (void)mouseEntered:(NSEvent *)event {
    [self trackHoverWithEvent:event];
    [self updateLowLatency];
    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)event {
    [self trackHoverWithEvent:event];
    // The bar shows on hover, its segments light under the mouse
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    _hovering = NO;
    [self updateLowLatency];
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    for (const BarSegment &segment : [self barSegmentsFor:[self waveformRect] box:nullptr]) {
        if (CGRectContainsPoint(segment.rect, p)) {
            _seeking = NO;
            [self performBarControl:segment];
            return;
        }
    }
    // Option-drag moves the loop, by whole beats
    if ((event.modifierFlags & NSEventModifierFlagOption) && _loop.active() && [self mixerReady] &&
        p.x < CGRectGetMaxX([self waveformRect])) {
        _seeking = NO;
        _loopDragging = YES;
        _loopDragOrigin = _loopDragPreview = _loop;
        _loopDragBeat = waveseek::beatPosition([self beats], [self secondsAtX:p.x]);
        [[NSCursor closedHandCursor] push];
        return;
    }
    if (CGRectContainsPoint([self zoomButtonRectFor:[self waveformRect]], p)) {
        _seeking = NO;
        _zoom.reset();
        // Following goes off with the zoom
        if (_followMode != waveform_config::FollowNone) {
            waveform_config::setConfigInt(waveform_config::kKeyZoomFollow, waveform_config::FollowNone);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"WaveformSeekbarSettingsChanged" object:nil];
        }
        [self setNeedsDisplay:YES];
        return;
    }
    // Not on the level scale: clamped, a click there would seek to the end
    // and skip to the next track
    const CGFloat x = p.x;
    _seeking = x < CGRectGetMaxX([self waveformRect]);
    if (_seeking) [self handleSeekWithEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
    _hoverX = [self convertPoint:event.locationInWindow fromView:nil].x;
    if (_loopDragging) {
        const long count = std::lround(waveseek::beatPosition([self beats], [self secondsAtX:_hoverX]) - _loopDragBeat);
        const waveseek::BeatLoop moved = waveseek::movedLoop([self beats], _loopDragOrigin, static_cast<int>(count),
                                                             self.trackDuration);
        if (moved.active()) _loopDragPreview = moved;
        [self setNeedsDisplay:YES];
        return;
    }
    if (_seeking) [self handleSeekWithEvent:event];
}

- (void)mouseUp:(NSEvent *)event {
    _seeking = NO;
    if (_loopDragging) {
        _loopDragging = NO;
        [NSCursor pop];
        const long count = _loopDragPreview.firstBeat - _loopDragOrigin.firstBeat;
        if (count != 0 && _loop.active() && _loop.firstBeat == _loopDragOrigin.firstBeat) {
            [self moveLoopBy:static_cast<int>(count)];
        }
        [self setNeedsDisplay:YES];
    }
}

// The track time under x in the waveform
- (double)secondsAtX:(CGFloat)x {
    const CGRect wave = [self waveformRect];
    const double across = (x - wave.origin.x) / std::max<CGFloat>(1.0, wave.size.width);
    return std::clamp(_zoom.positionAt(across), 0.0, 1.0) * self.trackDuration;
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
    const CGFloat across = std::clamp<CGFloat>((location.x - wave.origin.x) / std::max<CGFloat>(1.0, wave.size.width),
                                               0.0, 1.0);
    double seekTime = _zoom.positionAt(across) * self.trackDuration;
    // With the mixer, a click near a beat plays from the beat, on the beat
    bool onBeat = false;
    if ([self mixerReady]) {
        const double beat = waveseek::nearestBeat([self beats], seekTime);
        const CGFloat beatX = wave.origin.x + wave.size.width * _zoom.acrossOf(beat / self.trackDuration);
        if (!std::isnan(beat) && std::fabs(beatX - location.x) <= kBeatSnapPoints) {
            seekTime = beat;
            onBeat = true;
        }
    }
    // Following at a spot: the cursor stays where it was clicked
    if ([self following]) {
        const double clicked = _zoom.acrossOf(seekTime / self.trackDuration);
        if (clicked >= 0.0 && clicked <= 1.0) {
            _followSpot = clicked;
            _followSpotSet = true;
        }
    }

    // With the loop DSP, inside its audio without a seek
    if ([self deckMode]) {
        [self deckSeekTo:seekTime by:NAN onBeat:onBeat];
        return;
    }
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

#pragma mark - Zoom

- (BOOL)canZoom {
    return _zoomEnabled && self.waveformData && self.waveformData->isValid() && self.trackDuration > 0.0;
}

// About the pointer, within the zoom the track's analysis supports: its
// blocks, or the fine detail's when there is one
- (void)zoomBy:(double)factor event:(NSEvent *)event {
    const CGRect wave = [self waveformRect];
    const CGFloat x = [self convertPoint:event.locationInWindow fromView:nil].x;
    const double across = (x - wave.origin.x) / std::max<CGFloat>(1.0, wave.size.width);
    const WaveformDetail *detail = [self usableDetail];
    const size_t blocks = detail ? detail->blockCount() : self.waveformData->blockCount();
    // Centred, it zooms about the cursor and stays centred
    const bool centred = [self following] && _followMode == waveform_config::FollowCentre;
    const double about = centred ? _zoom.acrossOf(std::clamp(_playbackPosition, 0.0, 1.0)) : across;
    _zoom.zoomBy(factor, about, waveseek::maxZoomFor(blocks, wave.size.width));
    _lastZoomChange = CFAbsoluteTimeGetCurrent();
    [self followCursor];
    [self takeFollowSpot];
    [self setNeedsDisplay:YES];
}

// Vertical scroll zooms: away from you zooms in, whatever the scroll
// direction setting, and momentum doesn't keep zooming. Horizontal scroll
// (or Shift with a wheel) pans while zoomed in, the waveform following the
// fingers.
- (void)scrollWheel:(NSEvent *)event {
    if (![self canZoom]) {
        [super scrollWheel:event];
        return;
    }
    const bool precise = event.hasPreciseScrollingDeltas;
    const CGFloat dx = event.scrollingDeltaX, dy = event.scrollingDeltaY;
    if (std::fabs(dx) > std::fabs(dy)) {
        if (!_zoom.zoomed()) {
            [super scrollWheel:event];
            return;
        }
        // Centred, the cursor holds the view in place
        if ([self following] && _followMode == waveform_config::FollowCentre) return;
        const CGFloat points = precise ? dx : dx * kPanPointsPerLine;
        _zoom.panBy(-points / std::max<CGFloat>(1.0, [self waveformRect].size.width));
        [self takeFollowSpot];
        [self setNeedsDisplay:YES];
        return;
    }
    if (dy == 0.0 || event.momentumPhase != NSEventPhaseNone) return;
    const CGFloat away = event.isDirectionInvertedFromDevice ? -dy : dy;
    [self zoomBy:std::exp2(away * (precise ? kZoomOctavesPerPoint : kZoomOctavesPerLine)) event:event];
}

- (void)magnifyWithEvent:(NSEvent *)event {
    if (![self canZoom]) {
        [super magnifyWithEvent:event];
        return;
    }
    [self zoomBy:std::exp(event.magnification) event:event];
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
