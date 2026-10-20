//
//  SpectrumPreferences.mm
//  foo_jl_spectrum_mac
//
//  Preferences page laid out like P31 Spectrum's settings page: Display,
//  Analysis, Motion and Appearance sections of rows, where rows that do not
//  apply to the current settings are hidden (and the page closes up) or
//  disabled with a note saying why. Factory presets sit at the top.
//

#import "SpectrumPreferences.h"
#include "../fb2k_sdk.h"
#include "../Core/SpectrumConfig.h"
#include "../Core/SpectrumThemes.h"
#import "../../../../shared/PreferencesCommon.h"
#include "../Integration/ComponentInfo.h"
#include <functional>
#include <string>
#include <vector>

// Uniquely-named flipped view (avoids ObjC runtime clashes across components)
@interface SpectrumFlippedView : NSView
@end
@implementation SpectrumFlippedView
- (BOOL)isFlipped { return YES; }
@end

using namespace spectrum_config;

namespace {

constexpr CGFloat kPageWidth = 500;   // fits the preferences pane, with room for the longest note
constexpr CGFloat kLabelX = 30;
constexpr CGFloat kControlX = 160;
constexpr CGFloat kValueX = kControlX + 160;   // slider value / note
constexpr CGFloat kRowHeight = 30;
constexpr CGFloat kCheckboxHeight = 26;

enum class RowKind { Section, Popup, Slider, Checkbox, Number, ColorPair };

struct Choice {
    NSString *title;
    int value;
};

// One row of the page. get/set read and write config; the optional blocks
// decide whether the row shows, whether it can be changed, and the note shown
// in place of its value while it cannot.
struct Row {
    RowKind kind = RowKind::Section;
    NSTextField *label = nil;
    NSControl *control = nil;       // popup, slider, checkbox, number field, or light color well
    NSColorWell *darkWell = nil;    // color pair
    NSTextField *value = nil;       // slider value, number unit, or note
    NSTextField *lightCaption = nil, *darkCaption = nil;
    CGFloat controlWidth = 150;
    int step = 1;
    std::function<int()> get;
    std::function<void(int)> set;
    std::function<NSString *(int)> format;
    std::function<bool()> visible;
    std::function<bool()> enabled;
    std::function<NSString *()> note;
    const char *keyLight = nullptr, *keyDark = nullptr;    // color pair
};

NSString *fmt(NSString *format, int v) { return [NSString stringWithFormat:format, v]; }

int configInt(const char *key, int def) { return (int)getConfigInt(key, def); }
bool configBool(const char *key, bool def) { return getConfigBool(key, def); }

bool curveMode() { return configInt(kKeyDrawMode, kDefaultDrawMode) == DrawModeCurve; }
bool colorBarStyle() {
    const int style = configInt(kKeyCurveStyle, kDefaultCurveStyle);
    return curveMode() && (style == CurveStyleColorBars || style == CurveStyleLineColorBars);
}
// Color bars without a line: no peak line and no legend either.
bool colorBarsOnly() {
    return curveMode() && configInt(kKeyCurveStyle, kDefaultCurveStyle) == CurveStyleColorBars;
}

// --- Factory presets (P31 Spectrum's) ---

// Every setting to its default. Glass background is left alone: it is a
// window effect, not part of the analyzer's look the presets describe.
void writeDefaults() {
    setConfigInt(kKeyDrawMode, kDefaultDrawMode);
    setConfigInt(kKeyCurveStyle, kDefaultCurveStyle);
    setConfigInt(kKeyCurveOctaveFraction, kDefaultCurveOctaveFraction);
    setConfigInt(kKeyColorBarBrightness, kDefaultColorBarBrightness);
    setConfigInt(kKeyBarCount, kDefaultBarCount);
    setConfigInt(kKeyBarStyle, kDefaultBarStyle);
    setConfigInt(kKeyGapPercent, kDefaultGapPercent);
    setConfigInt(kKeyOrientation, kDefaultOrientation);
    setConfigInt(kKeyTopDb, kDefaultTopDb);
    setConfigInt(kKeyRangeDb, kDefaultRangeDb);
    setConfigBool(kKeyPeakHold, kDefaultPeakHold);
    setConfigBool(kKeyShadowFill, kDefaultShadowFill);
    setConfigBool(kKeyShowDbGuides, kDefaultShowDbGuides);
    setConfigBool(kKeyShowFreqAxis, kDefaultShowFreqAxis);
    setConfigBool(kKeyShowLegend, kDefaultShowLegend);
    setConfigInt(kKeyFftSize, kDefaultFftSize);
    setConfigInt(kKeyWindow, kDefaultWindow);
    setConfigInt(kKeyStereoMode, kDefaultStereoMode);
    setConfigInt(kKeyFreqScale, kDefaultFreqScale);
    setConfigInt(kKeyMinHz, kDefaultMinHz);
    setConfigInt(kKeyMaxHz, kDefaultMaxHz);
    setConfigInt(kKeySlopeTenths, kDefaultSlopeTenths);
    setConfigInt(kKeySmoothingMode, kDefaultSmoothingMode);
    setConfigInt(kKeySmoothing, kDefaultSmoothing);
    setConfigInt(kKeyRmsMs, kDefaultRmsMs);
    setConfigInt(kKeyShadowFallSpeed, kDefaultShadowFallSpeed);
    setConfigInt(kKeyPeakFallDbPerSec, kDefaultPeakFallDbPerSec);
    setConfigInt(kKeyPeakHoldMs, kDefaultPeakHoldMs);
    setConfigInt(kKeyGridOpacity, kDefaultGridOpacity);
    setConfigInt(kKeyTheme, kDefaultTheme);
    setConfigInt(kKeyBarColorLight, kDefaultBarColorLight);
    setConfigInt(kKeyBgColorLight, kDefaultBgColorLight);
    setConfigInt(kKeyGridColorLight, kDefaultGridColorLight);
    setConfigInt(kKeyBarColorDark, kDefaultBarColorDark);
    setConfigInt(kKeyBgColorDark, kDefaultBgColorDark);
    setConfigInt(kKeyGridColorDark, kDefaultGridColorDark);
}

struct Preset {
    NSString *name;
    void (*apply)();   // runs after writeDefaults()
};

const Preset kPresets[] = {
    {@"Default", [] {}},
    {@"Classic bars", [] {
        setConfigInt(kKeyDrawMode, DrawModeBars);
        setConfigInt(kKeyBarCount, 48);
        setConfigInt(kKeySmoothingMode, SmoothingAttackDecay);
        setConfigInt(kKeySmoothing, 60);
        setConfigInt(kKeyFreqScale, FreqScaleLog);
    }},
    {@"RTA, 1/3 octave", [] {
        setConfigInt(kKeyCurveStyle, CurveStyleFilled);
        setConfigInt(kKeyCurveOctaveFraction, 3);
        setConfigInt(kKeyFreqScale, FreqScaleLog);
        setConfigInt(kKeyFftSize, 8192);
        setConfigInt(kKeyRmsMs, 500);
    }},
    {@"Fine detail", [] {
        setConfigInt(kKeyCurveStyle, CurveStyleLine);
        setConfigInt(kKeyCurveOctaveFraction, 0);
        setConfigInt(kKeyFftSize, 16384);
        setConfigInt(kKeyWindow, WindowBlackmanHarris);
        setConfigInt(kKeyFreqScale, FreqScaleLog);
        setConfigInt(kKeyRangeDb, 120);
    }},
    {@"Mid + side", [] {
        setConfigInt(kKeyStereoMode, StereoMidSide);
        setConfigInt(kKeyCurveStyle, CurveStyleLine);
        setConfigInt(kKeyCurveOctaveFraction, 12);
    }},
};

} // namespace

@interface SpectrumPreferences () {
    SpectrumFlippedView *_page;
    NSPopUpButton *_presetPopup;
    std::vector<Row> _rows;
    NSInteger _themeRow;
}
@end

@implementation SpectrumPreferences

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (NSString *)preferencesTitle { return @"Spectrum Analyzer"; }

- (void)loadView {
    // The rows live in a flipped page inside a scroll view, so a preferences
    // window shorter than the page can scroll.
    _page = [[SpectrumFlippedView alloc] initWithFrame:NSMakeRect(0, 0, kPageWidth, 1000)];
    _page.autoresizingMask = 0;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, kPageWidth, 600)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.documentView = _page;
    self.view = scroll;

    [NSColor setIgnoresAlpha:NO];
    [NSColorPanel sharedColorPanel].showsAlpha = YES;
    [self buildRows];
    [self loadValues];
    [self refresh];
}

#pragma mark - Rows

- (NSTextField *)labelWithText:(NSString *)text {
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 17)];
    l.stringValue = text; l.editable = NO; l.bordered = NO; l.selectable = NO;
    l.backgroundColor = [NSColor clearColor];
    l.font = [NSFont systemFontOfSize:11];
    return l;
}

- (NSInteger)addRow:(Row)row {
    const NSInteger index = (NSInteger)_rows.size();
    if (row.control) {
        row.control.tag = index;
        row.control.target = self;
        row.control.action = @selector(rowChanged:);
        [_page addSubview:row.control];
    }
    if (row.darkWell) {
        row.darkWell.tag = index;
        row.darkWell.target = self;
        row.darkWell.action = @selector(rowChanged:);
        [_page addSubview:row.darkWell];
    }
    for (NSView *v in @[row.label ?: [NSNull null], row.value ?: [NSNull null],
                        row.lightCaption ?: [NSNull null], row.darkCaption ?: [NSNull null]]) {
        if ([v isKindOfClass:[NSView class]]) [_page addSubview:v];
    }
    _rows.push_back(std::move(row));
    return index;
}

- (void)section:(NSString *)title {
    Row r;
    r.kind = RowKind::Section;
    r.label = JLCreateSectionHeader(title);
    [self addRow:std::move(r)];
}

- (Row)popup:(NSString *)label choices:(std::vector<Choice>)choices width:(CGFloat)width
         get:(std::function<int()>)get set:(std::function<void(int)>)set tooltip:(NSString *)tooltip {
    Row r;
    r.kind = RowKind::Popup;
    r.label = [self labelWithText:[label stringByAppendingString:@":"]];
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, width, 25)];
    for (const Choice &c : choices) {   // item tags hold the stored value
        [p addItemWithTitle:c.title];
        p.lastItem.tag = c.value;
    }
    p.toolTip = tooltip;
    r.control = p;
    r.controlWidth = width;
    r.get = std::move(get);
    r.set = std::move(set);
    return r;
}

- (Row)slider:(NSString *)label min:(int)lo max:(int)hi
          get:(std::function<int()>)get set:(std::function<void(int)>)set
       format:(std::function<NSString *(int)>)format tooltip:(NSString *)tooltip {
    Row r;
    r.kind = RowKind::Slider;
    r.label = [self labelWithText:[label stringByAppendingString:@":"]];
    NSSlider *s = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 150, 22)];
    s.minValue = lo; s.maxValue = hi; s.continuous = YES;
    s.toolTip = tooltip;
    r.control = s;
    r.value = [self labelWithText:@""];
    r.get = std::move(get);
    r.set = std::move(set);
    r.format = std::move(format);
    return r;
}

- (Row)checkbox:(NSString *)title get:(std::function<int()>)get set:(std::function<void(int)>)set
        tooltip:(NSString *)tooltip {
    Row r;
    r.kind = RowKind::Checkbox;
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 260, 20)];
    b.buttonType = NSButtonTypeSwitch;
    b.title = title;
    b.toolTip = tooltip;
    r.control = b;
    r.get = std::move(get);
    r.set = std::move(set);
    return r;
}

- (Row)number:(NSString *)label min:(int)lo max:(int)hi unit:(NSString *)unit
          get:(std::function<int()>)get set:(std::function<void(int)>)set tooltip:(NSString *)tooltip {
    Row r;
    r.kind = RowKind::Number;
    r.label = [self labelWithText:[label stringByAppendingString:@":"]];
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 70, 22)];
    NSNumberFormatter *nf = [[NSNumberFormatter alloc] init];
    nf.numberStyle = NSNumberFormatterNoStyle;
    nf.minimum = @(lo); nf.maximum = @(hi);
    nf.allowsFloats = NO;
    f.formatter = nf;
    f.toolTip = tooltip;
    r.control = f;
    r.value = [self labelWithText:unit];
    r.get = std::move(get);
    r.set = std::move(set);
    return r;
}

- (NSColorWell *)colorWell {
    NSColorWell *w = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 40, 24)];
    if (@available(macOS 13.0, *)) { w.colorWellStyle = NSColorWellStyleMinimal; }
    return w;
}

- (void)colorPair:(NSString *)label light:(const char *)keyLight dark:(const char *)keyDark {
    Row r;
    r.kind = RowKind::ColorPair;
    r.label = [self labelWithText:[label stringByAppendingString:@":"]];
    r.control = [self colorWell];
    r.darkWell = [self colorWell];
    r.lightCaption = [self labelWithText:@"Light"];
    r.darkCaption = [self labelWithText:@"Dark"];
    r.lightCaption.textColor = r.darkCaption.textColor = [NSColor secondaryLabelColor];
    r.keyLight = keyLight;
    r.keyDark = keyDark;
    [self addRow:std::move(r)];
}

- (void)buildRows {
    NSTextField *title = JLCreatePreferencesTitle(@"Spectrum Analyzer");
    title.frame = NSMakeRect(20, 10, 400, 20);
    [_page addSubview:title];
    JLAddPreferencesInfoButton(_page, title, self, @selector(showComponentInfo:));

    // Presets: a pull-down, so it always reads "Apply preset" rather than
    // claiming the current settings match one.
    [_page addSubview:({
        NSTextField *l = [self labelWithText:@"Preset:"];
        l.frame = NSMakeRect(kLabelX, 43, 120, 17);
        l;
    })];
    _presetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(kControlX, 40, 170, 25) pullsDown:YES];
    [_presetPopup addItemWithTitle:@"Apply preset…"];
    for (const Preset &preset : kPresets) [_presetPopup addItemWithTitle:preset.name];
    _presetPopup.toolTip = @"Replaces every setting (colors included) with the preset's; Default restores all defaults";
    _presetPopup.target = self; _presetPopup.action = @selector(presetChosen:);
    [_page addSubview:_presetPopup];

    const auto intKey = [](const char *key, int def) {
        return std::make_pair([key, def] { return configInt(key, def); }, [key](int v) { setConfigInt(key, v); });
    };
    const auto boolKey = [](const char *key, bool def) {
        return std::make_pair([key, def] { return configBool(key, def) ? 1 : 0; }, [key](int v) { setConfigBool(key, v != 0); });
    };
    const auto curve = [] { return curveMode(); };
    const auto bars = [] { return !curveMode(); };

    // --- Display ---
    [self section:@"Display"];
    {
        auto [g, s] = intKey(kKeyDrawMode, kDefaultDrawMode);
        [self addRow:[self popup:@"Draw mode" choices:{{@"Curve", DrawModeCurve}, {@"Bars", DrawModeBars}}
                           width:130 get:g set:s tooltip:nil]];
    }
    {
        auto [g, s] = intKey(kKeyCurveStyle, kDefaultCurveStyle);
        Row r = [self popup:@"Curve style"
                    choices:{{@"Filled", CurveStyleFilled}, {@"Line", CurveStyleLine},
                             {@"Color bars", CurveStyleColorBars}, {@"Line + color bars", CurveStyleLineColorBars}}
                      width:170 get:g set:s
                    tooltip:@"Color bars are stripes that get brighter where a frequency is louder"];
        r.visible = curve;
        [self addRow:std::move(r)];
    }
    {
        std::vector<Choice> detail;
        for (int fraction : kCurveOctaveFractions) {
            detail.push_back({fraction == 0 ? @"Full" : [NSString stringWithFormat:@"1/%d octave", fraction], fraction});
        }
        Row r = [self popup:@"Curve detail" choices:detail width:130
                        get:[] { return getCurveOctaveFraction(); }
                        set:[](int v) { setConfigInt(kKeyCurveOctaveFraction, v); }
                    tooltip:@"Full draws every FFT bin; an octave fraction averages the power around each point for a smoother curve"];
        r.visible = curve;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyColorBarBrightness, kDefaultColorBarBrightness);
        Row r = [self slider:@"Color bar brightness" min:10 max:100 get:g set:s
                      format:[](int v) { return fmt(@"%d%%", v); } tooltip:@"How strong the loudest color bar gets"];
        r.visible = curve;
        r.enabled = [] { return colorBarStyle(); };
        r.note = [] { return @"Color bar styles only"; };
        [self addRow:std::move(r)];
    }
    {
        std::vector<Choice> counts{{@"Auto", kBarCountAuto}};
        for (int n : {16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512}) counts.push_back({fmt(@"%d", n), n});
        auto [g, s] = intKey(kKeyBarCount, kDefaultBarCount);
        Row r = [self popup:@"Bars" choices:counts width:100 get:g set:s
                    tooltip:@"Auto draws one bar per 2 points of panel width"];
        r.visible = bars;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyBarStyle, kDefaultBarStyle);
        Row r = [self popup:@"Bar style"
                    choices:{{@"Solid", BarStyleSolid}, {@"Gradient", BarStyleGradient}, {@"Spectrum", BarStyleSpectrum}}
                      width:130 get:g set:s tooltip:nil];
        r.visible = bars;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyGapPercent, kDefaultGapPercent);
        Row r = [self slider:@"Bar gap" min:0 max:80 get:g set:s format:[](int v) { return fmt(@"%d%%", v); } tooltip:nil];
        r.visible = bars;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyOrientation, kDefaultOrientation);
        [self addRow:[self popup:@"Orientation" choices:{{@"Horizontal", OrientationHorizontal}, {@"Vertical", OrientationVertical}}
                           width:130 get:g set:s tooltip:nil]];
    }
    [self addRow:[self slider:@"Top" min:kMinTopDb max:kMaxTopDb
                          get:[] { return getTopDb(); } set:[](int v) { setConfigInt(kKeyTopDb, v); }
                       format:[](int v) { return fmt(@"%d dB", v); }
                      tooltip:@"Level at the top of the display; lower it to fill the height with quiet music"]];
    {
        std::vector<Choice> ranges;
        for (int range : kRangeDbChoices) ranges.push_back({fmt(@"%d dB", range), range});
        [self addRow:[self popup:@"Range" choices:ranges width:100
                             get:[] { return getRangeDb(); } set:[](int v) { setConfigInt(kKeyRangeDb, v); }
                         tooltip:@"dB from the top of the display to the bottom"]];
    }
    {
        auto [g, s] = boolKey(kKeyPeakHold, kDefaultPeakHold);
        Row r = [self checkbox:@"Show peaks" get:g set:s
                       tooltip:@"Peak caps in Bars mode, a peak line in Curve mode; not drawn with color bars alone"];
        r.enabled = [] { return !colorBarsOnly(); };
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeyShadowFill, kDefaultShadowFill);
        Row r = [self checkbox:@"Shadow fill" get:g set:s tooltip:@"Dim, slow-falling fill behind the levels; not drawn with color bars"];
        r.enabled = [] { return !colorBarStyle(); };
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeyShowDbGuides, kDefaultShowDbGuides);
        [self addRow:[self checkbox:@"Show dB scale" get:g set:s tooltip:nil]];
    }
    {
        auto [g, s] = boolKey(kKeyShowFreqAxis, kDefaultShowFreqAxis);
        [self addRow:[self checkbox:@"Show frequency axis" get:g set:s
                            tooltip:@"Frequency gridlines and labels (in Bars mode, each bar's centre frequency)"]];
    }
    {
        auto [g, s] = boolKey(kKeyShowLegend, kDefaultShowLegend);
        Row r = [self checkbox:@"Show legend" get:g set:s tooltip:@"The Live / Peak hold key in the plot's top-left corner"];
        r.visible = curve;
        r.enabled = [] { return !colorBarsOnly(); };
        [self addRow:std::move(r)];
    }

    // --- Analysis ---
    [self section:@"Analysis"];
    {
        std::vector<Choice> sizes;
        for (int n : kFftSizes) sizes.push_back({fmt(@"%d", n), n});
        auto [g, s] = intKey(kKeyFftSize, kDefaultFftSize);
        [self addRow:[self popup:@"FFT size" choices:sizes width:100 get:g set:s
                         tooltip:@"Larger sizes resolve low frequencies better but react more slowly"]];
    }
    [self addRow:[self popup:@"Window" choices:{{@"Hann", WindowHann}, {@"Blackman-Harris", WindowBlackmanHarris}}
                       width:150 get:[] { return getWindowType(); } set:[](int v) { setConfigInt(kKeyWindow, v); }
                     tooltip:@"Blackman-Harris keeps loud tones from spilling into quiet neighbours, at the cost of wider peaks"]];
    {
        auto [g, s] = intKey(kKeyStereoMode, kDefaultStereoMode);
        [self addRow:[self popup:@"Stereo" choices:{{@"Mono", StereoMono}, {@"Mid + side", StereoMidSide}}
                           width:130 get:g set:s tooltip:@"Mid + side adds the stereo difference (L-R) as a second line"]];
    }
    {
        auto [g, s] = intKey(kKeyFreqScale, kDefaultFreqScale);
        [self addRow:[self popup:@"Frequency scale"
                         choices:{{@"Logarithmic", FreqScaleLog}, {@"Linear", FreqScaleLinear},
                                  {@"Logarithmic (compact bass)", FreqScaleSoftLog}}
                           width:210 get:g set:s tooltip:nil]];
    }
    [self addRow:[self number:@"Lowest frequency" min:10 max:2000 unit:@"Hz"
                          get:[] { return configInt(kKeyMinHz, kDefaultMinHz); }
                          set:[](int v) {
                              setConfigInt(kKeyMinHz, v);
                              if (configInt(kKeyMaxHz, kDefaultMaxHz) < v + 100) setConfigInt(kKeyMaxHz, v + 100);
                          }
                      tooltip:nil]];
    [self addRow:[self number:@"Highest frequency" min:1000 max:24000 unit:@"Hz"
                          get:[] { return configInt(kKeyMaxHz, kDefaultMaxHz); }
                          set:[](int v) {
                              setConfigInt(kKeyMaxHz, std::max(v, configInt(kKeyMinHz, kDefaultMinHz) + 100));
                          }
                      tooltip:@"Limited to half the sample rate"]];
    {
        auto [g, s] = intKey(kKeySlopeTenths, kDefaultSlopeTenths);
        [self addRow:[self slider:@"Slope" min:0 max:kMaxSlopeTenths get:g set:s
                           format:[](int v) { return [NSString stringWithFormat:@"%.1f dB/oct", v / 10.0]; }
                          tooltip:@"Tilts the spectrum around 1 kHz so high frequencies read higher"]];
    }

    // --- Motion ---
    [self section:@"Motion"];
    {
        auto [g, s] = intKey(kKeySmoothingMode, kDefaultSmoothingMode);
        [self addRow:[self popup:@"Smoothing mode"
                         choices:{{@"Attack / decay", SmoothingAttackDecay}, {@"RMS average", SmoothingRms}}
                           width:150 get:g set:s
                         tooltip:@"RMS average averages signal power over time, so levels rise and fall evenly like a real-time analyzer"]];
    }
    const auto rms = [] { return configInt(kKeySmoothingMode, kDefaultSmoothingMode) == SmoothingRms; };
    {
        auto [g, s] = intKey(kKeySmoothing, kDefaultSmoothing);
        Row r = [self slider:@"Smoothing" min:0 max:100 get:g set:s format:[](int v) { return fmt(@"%d", v); } tooltip:nil];
        r.visible = [rms] { return !rms(); };
        [self addRow:std::move(r)];
    }
    {
        Row r = [self slider:@"Averaging time" min:0 max:kMaxRmsMs
                         get:[] { return getRmsMs(); } set:[](int v) { setConfigInt(kKeyRmsMs, v); }
                      format:[](int v) { return fmt(@"%d ms", v); } tooltip:nil];
        r.step = 5;
        r.visible = rms;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyShadowFallSpeed, kDefaultShadowFallSpeed);
        Row r = [self slider:@"Shadow fall" min:0 max:100 get:g set:s format:[](int v) { return fmt(@"%d", v); }
                     tooltip:@"How fast the shadow falls (higher = faster)"];
        r.enabled = [] { return !colorBarStyle() && configBool(kKeyShadowFill, kDefaultShadowFill); };
        r.note = [] { return colorBarStyle() ? @"Not drawn with color bars" : @"Shadow fill is off"; };
        [self addRow:std::move(r)];
    }
    const auto peaksOn = [] { return configBool(kKeyPeakHold, kDefaultPeakHold) && !colorBarsOnly(); };
    const auto peaksOffNote = [] { return colorBarsOnly() ? @"Not drawn with color bars" : @"Show peaks is off"; };
    {
        Row r = [self slider:@"Peak fall" min:kMinPeakFallDbPerSec max:kMaxPeakFallDbPerSec
                         get:[] { return getPeakFallDbPerSec(); } set:[](int v) { setConfigInt(kKeyPeakFallDbPerSec, v); }
                      format:[](int v) { return fmt(@"%d dB/s", v); } tooltip:@"How fast peaks fall after their hold"];
        r.enabled = peaksOn;
        r.note = peaksOffNote;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyPeakHoldMs, kDefaultPeakHoldMs);
        Row r = [self slider:@"Peak hold" min:0 max:kMaxPeakHoldMs get:g set:s format:[](int v) { return fmt(@"%d ms", v); }
                     tooltip:@"How long a peak stays before it falls"];
        r.step = 10;
        r.enabled = peaksOn;
        r.note = peaksOffNote;
        [self addRow:std::move(r)];
    }

    // --- Appearance ---
    [self section:@"Appearance"];
    {
        std::vector<Choice> themes;
        for (int index : kThemeMenuOrder) themes.push_back({[NSString stringWithUTF8String:kThemes[index].name], index});
        _themeRow = [self addRow:[self popup:@"Theme" choices:themes width:160
                                         get:[] {
                                             const int t = configInt(kKeyTheme, kDefaultTheme);
                                             return t >= 0 && t < kThemeCount ? t : 0;
                                         }
                                         set:[](int v) {
                                             setConfigInt(kKeyTheme, v);
                                             applyThemeToConfig(v);   // no-op for Custom
                                         }
                                     tooltip:@"A color preset for levels, background and grid"]];
    }
    {
        auto [g, s] = intKey(kKeyGridOpacity, kDefaultGridOpacity);
        [self addRow:[self slider:@"Grid opacity" min:0 max:100 get:g set:s format:[](int v) { return fmt(@"%d%%", v); } tooltip:nil]];
    }
    [self colorPair:@"Levels" light:kKeyBarColorLight dark:kKeyBarColorDark];
    [self colorPair:@"Background" light:kKeyBgColorLight dark:kKeyBgColorDark];
    [self colorPair:@"Grid" light:kKeyGridColorLight dark:kKeyGridColorDark];
    {
        auto [g, s] = boolKey(kKeyGlassBackground, kDefaultGlassBackground);
        [self addRow:[self checkbox:@"Glass background" get:g set:s tooltip:@"Translucent blur background instead of a solid color"]];
    }
}

#pragma mark - Values and layout

- (NSColor *)colorFromARGB:(uint32_t)argb {
    return [NSColor colorWithSRGBRed:((argb >> 16) & 0xFF) / 255.0
                               green:((argb >> 8) & 0xFF) / 255.0
                                blue:(argb & 0xFF) / 255.0
                               alpha:((argb >> 24) & 0xFF) / 255.0];
}

- (uint32_t)argbFromColor:(NSColor *)color {
    NSColor *c = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!c) return 0xFF000000;
    uint32_t a = (uint32_t)(c.alphaComponent * 255) & 0xFF;
    uint32_t r = (uint32_t)(c.redComponent * 255) & 0xFF;
    uint32_t g = (uint32_t)(c.greenComponent * 255) & 0xFF;
    uint32_t b = (uint32_t)(c.blueComponent * 255) & 0xFF;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

// Default colors for a color-pair key.
- (uint32_t)defaultColorForKey:(const char *)key {
    const std::string k(key);
    if (k == kKeyBarColorLight) return kDefaultBarColorLight;
    if (k == kKeyBarColorDark) return kDefaultBarColorDark;
    if (k == kKeyBgColorLight) return kDefaultBgColorLight;
    if (k == kKeyBgColorDark) return kDefaultBgColorDark;
    if (k == kKeyGridColorLight) return kDefaultGridColorLight;
    return kDefaultGridColorDark;
}

- (void)loadValueOfRow:(Row &)r {
    switch (r.kind) {
        case RowKind::Section: break;
        case RowKind::Popup: {
            NSPopUpButton *p = (NSPopUpButton *)r.control;
            if (![p selectItemWithTag:r.get()]) [p selectItemAtIndex:0];
            break;
        }
        case RowKind::Slider:
            ((NSSlider *)r.control).integerValue = r.get();
            break;
        case RowKind::Checkbox:
            ((NSButton *)r.control).state = r.get() ? NSControlStateValueOn : NSControlStateValueOff;
            break;
        case RowKind::Number:
            ((NSTextField *)r.control).integerValue = r.get();
            break;
        case RowKind::ColorPair:
            ((NSColorWell *)r.control).color =
                [self colorFromARGB:(uint32_t)getConfigInt(r.keyLight, [self defaultColorForKey:r.keyLight])];
            r.darkWell.color = [self colorFromARGB:(uint32_t)getConfigInt(r.keyDark, [self defaultColorForKey:r.keyDark])];
            break;
    }
}

- (void)loadValues {
    for (Row &r : _rows) [self loadValueOfRow:r];
}

// Show, hide, enable and position every row for the current settings; hidden
// rows take no space.
- (void)refresh {
    CGFloat y = 76;
    bool first = true;
    for (Row &r : _rows) {
        const bool shown = !r.visible || r.visible();
        for (NSView *v in @[r.label ?: [NSNull null], r.control ?: [NSNull null], r.darkWell ?: [NSNull null],
                            r.value ?: [NSNull null], r.lightCaption ?: [NSNull null], r.darkCaption ?: [NSNull null]]) {
            if ([v isKindOfClass:[NSView class]]) v.hidden = !shown;
        }
        if (!shown) continue;

        const bool enabled = !r.enabled || r.enabled();
        switch (r.kind) {
            case RowKind::Section:
                if (!first) y += 12;
                r.label.frame = NSMakeRect(20, y, 300, 17);
                y += 24;
                break;
            case RowKind::Popup:
                r.label.frame = NSMakeRect(kLabelX, y + 4, kControlX - kLabelX - 6, 17);
                r.control.frame = NSMakeRect(kControlX, y, r.controlWidth, 25);
                y += kRowHeight;
                break;
            case RowKind::Slider: {
                r.label.frame = NSMakeRect(kLabelX, y + 3, kControlX - kLabelX - 6, 17);
                r.control.frame = NSMakeRect(kControlX, y, 150, 22);
                r.value.frame = NSMakeRect(kValueX, y + 3, kPageWidth - kValueX - 6, 17);
                // While disabled the value gives way to a note saying why.
                const bool showNote = !enabled && r.note;
                // The stored value: a stepped slider can sit between steps while dragged.
                r.value.stringValue = showNote ? r.note() : r.format(r.get());
                r.value.textColor = showNote ? [NSColor secondaryLabelColor] : [NSColor labelColor];
                y += kRowHeight;
                break;
            }
            case RowKind::Checkbox:
                r.control.frame = NSMakeRect(kLabelX, y, kPageWidth - kLabelX - 10, 20);
                y += kCheckboxHeight;
                break;
            case RowKind::Number:
                r.label.frame = NSMakeRect(kLabelX, y + 3, kControlX - kLabelX - 6, 17);
                r.control.frame = NSMakeRect(kControlX, y, 70, 22);
                r.value.frame = NSMakeRect(kControlX + 76, y + 3, 40, 17);
                y += kRowHeight;
                break;
            case RowKind::ColorPair:
                r.label.frame = NSMakeRect(kLabelX, y + 4, kControlX - kLabelX - 6, 17);
                r.control.frame = NSMakeRect(kControlX, y, 40, 24);
                r.lightCaption.frame = NSMakeRect(kControlX + 46, y + 4, 40, 17);
                r.darkWell.frame = NSMakeRect(kControlX + 100, y, 40, 24);
                r.darkCaption.frame = NSMakeRect(kControlX + 146, y + 4, 40, 17);
                y += kRowHeight + 2;
                break;
        }
        r.control.enabled = enabled;
        first = false;
    }
    [_page setFrameSize:NSMakeSize(kPageWidth, y + 20)];
}

- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:kSettingsChangedNotification object:nil];
}

#pragma mark - Actions

- (void)rowChanged:(NSControl *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)_rows.size()) return;
    Row &r = _rows[(size_t)sender.tag];
    switch (r.kind) {
        case RowKind::Section: return;
        case RowKind::Popup:
            r.set((int)((NSPopUpButton *)r.control).selectedItem.tag);
            break;
        case RowKind::Slider: {
            NSSlider *s = (NSSlider *)r.control;
            const int v = (int)std::lround(s.doubleValue / r.step) * r.step;
            r.set(v);
            break;
        }
        case RowKind::Checkbox:
            r.set(((NSButton *)r.control).state == NSControlStateValueOn ? 1 : 0);
            break;
        case RowKind::Number:
            r.set(((NSTextField *)r.control).intValue);
            break;
        case RowKind::ColorPair:
            setConfigInt(sender == r.control ? r.keyLight : r.keyDark,
                         [self argbFromColor:((NSColorWell *)sender).color]);
            // A manual color edit means the palette no longer matches a theme.
            setConfigInt(kKeyTheme, 0);
            break;
    }
    // A setting can change others (theme colors, frequency limits) and which
    // rows apply, so reload everything except the control being dragged.
    for (size_t i = 0; i < _rows.size(); ++i) {
        if ((NSInteger)i != sender.tag || r.kind == RowKind::Number) [self loadValueOfRow:_rows[i]];
    }
    [self refresh];
    [self notifyChanged];
}

- (void)presetChosen:(id)sender {
    const NSInteger index = _presetPopup.indexOfSelectedItem - 1;   // item 0 is the title
    if (index < 0 || index >= (NSInteger)(sizeof(kPresets) / sizeof(kPresets[0]))) return;
    writeDefaults();
    kPresets[index].apply();
    [self loadValues];
    [self refresh];
    [self notifyChanged];
}

- (void)showComponentInfo:(NSButton *)sender {
    JLShowComponentInfo(sender, JLComponentInfoRows());
}

@end

// --- Preferences page registration ---
namespace {
    class spectrum_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            return fb2k::wrapNSObject([[SpectrumPreferences alloc] init]);
        }
        const char* get_name() override { return "Spectrum Analyzer"; }
        GUID get_guid() override { return spectrum_config::guid_preferences_page; }
        GUID get_parent_guid() override { return preferences_page::guid_display; }
    };
    FB2K_SERVICE_FACTORY(spectrum_preferences_page);
}
