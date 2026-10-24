//
//  LevelMeterPreferences.mm
//  foo_jl_levelmeter_mac
//
//  Preferences page in the Spectrum Analyzer's style: sections of rows,
//  where rows that do not apply to the chosen style are hidden (and the page
//  closes up) or disabled with a note saying why.
//

#import "LevelMeterPreferences.h"
#include "../fb2k_sdk.h"
#include "../Core/LevelMeterConfig.h"
#import "../../../../shared/PreferencesCommon.h"
#import "../../../../shared/ThemeColor.h"
#include "../Integration/ComponentInfo.h"
#include <functional>
#include <vector>

// Uniquely-named flipped view (avoids ObjC runtime clashes across components)
@interface LevelMeterFlippedView : NSView
@end
@implementation LevelMeterFlippedView
- (BOOL)isFlipped { return YES; }
@end

using namespace levelmeter_config;

namespace {

constexpr CGFloat kPageWidth = 500;
constexpr CGFloat kLabelX = 30;
constexpr CGFloat kControlX = 160;
constexpr CGFloat kValueX = kControlX + 160;   // slider value / note
constexpr CGFloat kRowHeight = 30;
constexpr CGFloat kCheckboxHeight = 26;

enum class RowKind { Section, Popup, Slider, Checkbox, ColorPair };

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
    NSControl *control = nil;       // popup, slider, checkbox, or light color well
    NSColorWell *darkWell = nil;    // color pair
    NSTextField *value = nil;       // slider value or note
    NSTextField *lightCaption = nil, *darkCaption = nil;
    CGFloat controlWidth = 150;
    int step = 1;
    std::function<int()> get;
    std::function<void(int)> set;
    std::function<NSString *(int)> format;
    std::function<bool()> visible;
    std::function<bool()> enabled;
    std::function<NSString *()> note;
    int colorIndex = -1;            // color pair
};

NSString *fmt(NSString *format, int v) { return [NSString stringWithFormat:format, v]; }

int configInt(const char *key, int def) { return (int)getConfigInt(key, def); }
bool configBool(const char *key, bool def) { return getConfigBool(key, def); }

bool digital() { return configInt(kKeyStyle, kDefaultStyle) == (int)MeterStyle::Digital; }
bool analog() { return !digital(); }

} // namespace

@interface LevelMeterPreferences () {
    LevelMeterFlippedView *_page;
    std::vector<Row> _rows;
}
@end

@implementation LevelMeterPreferences

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (NSString *)preferencesTitle { return @"Level Meter"; }

- (void)loadView {
    // The rows live in a flipped page inside a scroll view, so a preferences
    // window shorter than the page can scroll.
    _page = [[LevelMeterFlippedView alloc] initWithFrame:NSMakeRect(0, 0, kPageWidth, 1000)];
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

    // Settings can change from outside this page too (the meter's context
    // menu switches the style), and foobar2000 keeps the page around.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChangedElsewhere:)
                                                 name:kSettingsChangedNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self loadValues];
    [self refresh];
}

- (void)settingsChangedElsewhere:(NSNotification *)note {
    if (note.object == self) return;   // our own change: controls are already current
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

- (void)section:(NSString *)title visible:(std::function<bool()>)visible {
    Row r;
    r.kind = RowKind::Section;
    r.label = JLCreateSectionHeader(title);
    r.visible = std::move(visible);
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

- (NSColorWell *)colorWell {
    NSColorWell *w = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 40, 24)];
    if (@available(macOS 13.0, *)) { w.colorWellStyle = NSColorWellStyleMinimal; }
    return w;
}

- (void)colorPair:(int)index {
    Row r;
    r.kind = RowKind::ColorPair;
    r.label = [self labelWithText:[NSString stringWithFormat:@"%s:", kColorNames[index]]];
    r.control = [self colorWell];
    r.darkWell = [self colorWell];
    r.lightCaption = [self labelWithText:@"Light"];
    r.darkCaption = [self labelWithText:@"Dark"];
    r.lightCaption.textColor = r.darkCaption.textColor = [NSColor secondaryLabelColor];
    r.colorIndex = index;
    [self addRow:std::move(r)];
}

- (void)buildRows {
    NSTextField *title = JLCreatePreferencesTitle(@"Level Meter");
    title.frame = NSMakeRect(20, 10, 400, 20);
    [_page addSubview:title];
    JLAddPreferencesInfoButton(_page, title, self, @selector(showComponentInfo:));

    const auto intKey = [](const char *key, int def) {
        return std::make_pair([key, def] { return configInt(key, def); }, [key](int v) { setConfigInt(key, v); });
    };
    const auto boolKey = [](const char *key, bool def) {
        return std::make_pair([key, def] { return configBool(key, def) ? 1 : 0; }, [key](int v) { setConfigBool(key, v != 0); });
    };
    const auto isDigital = [] { return digital(); };
    const auto isAnalog = [] { return analog(); };

    // --- Display ---
    [self section:@"Display" visible:nullptr];
    {
        auto [g, s] = intKey(kKeyStyle, kDefaultStyle);
        [self addRow:[self popup:@"Style" choices:{{@"Digital", (int)MeterStyle::Digital}, {@"Analog VU", (int)MeterStyle::Analog}}
                           width:150 get:g set:s
                         tooltip:@"Digital: bars, loudness and stereo figures. Analog VU: moving-coil needle faces"]];
    }
    {
        auto [g, s] = intKey(kKeyOrientation, kDefaultOrientation);
        Row r = [self popup:@"Orientation"
                    choices:{{@"Auto", (int)Orientation::Auto}, {@"Vertical", (int)Orientation::Vertical},
                             {@"Horizontal", (int)Orientation::Horizontal}}
                      width:130 get:g set:s tooltip:@"Auto runs the bars along the panel's longer side"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyBarMode, kDefaultBarMode);
        Row r = [self popup:@"Bars"
                    choices:{{@"Peak + RMS", (int)BarMode::PeakAndRms}, {@"Peak", (int)BarMode::Peak}, {@"RMS", (int)BarMode::Rms}}
                      width:130 get:g set:s
                    tooltip:@"Peak + RMS: the wide bar is RMS, the slim column above it the peak"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyScale, kDefaultScale);
        Row r = [self popup:@"Scale"
                    choices:{{@"dBFS", (int)ScaleType::Dbfs}, {@"K-20", (int)ScaleType::K20},
                             {@"K-14", (int)ScaleType::K14}, {@"K-12", (int)ScaleType::K12}}
                      width:100 get:g set:s
                    tooltip:@"K-system scales put 0 at -20 / -14 / -12 dBFS, green below 0, yellow to +4, red above"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeySpacing, kDefaultSpacing);
        Row r = [self popup:@"Scale spacing"
                    choices:{{@"Extended top", (int)ScaleSpacing::Extended}, {@"Linear", (int)ScaleSpacing::Linear}}
                      width:130 get:g set:s
                    tooltip:@"Extended gives the top 20 dB half the bar, so loud passages show more detail"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        std::vector<Choice> floors;
        for (int f : kFloorChoices) floors.push_back({fmt(@"%d dB", f), f});
        auto [g, s] = intKey(kKeyFloorDb, kDefaultFloorDb);
        Row r = [self popup:@"Range" choices:floors width:100 get:g set:s tooltip:@"Level at the bottom of the bars"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeySegments, kDefaultSegments);
        Row r = [self checkbox:@"LED segments" get:g set:s tooltip:@"Split the bars into segments like an LED meter"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeyShowReadouts, kDefaultShowReadouts);
        Row r = [self checkbox:@"Show readouts" get:g set:s
                       tooltip:@"Highest peak above each level bar (click to reset) and the loudness values"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeyShowLoudness, kDefaultShowLoudness);
        Row r = [self checkbox:@"Show loudness" get:g set:s
                       tooltip:@"Momentary and short-term bars, integrated loudness, range, true peak and PLR"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        Row r = [self checkbox:@"Show correlation" get:[] { return getShowCorrelation() ? 1 : 0; }
                           set:[](int v) { setConfigBool(kKeyShowCorrelation, v != 0); }
                       tooltip:@"Phase correlation: +1 = mono, 0 = wide, below 0 = out of phase"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        Row r = [self checkbox:@"Show balance" get:[] { return getShowBalance() ? 1 : 0; }
                           set:[](int v) { setConfigBool(kKeyShowBalance, v != 0); }
                       tooltip:@"Which channel is louder, full scale at 12 dB difference"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }

    // --- Levels ---
    [self section:@"Levels" visible:nullptr];
    {
        auto [g, s] = boolKey(kKeyTruePeak, kDefaultTruePeak);
        [self addRow:[self checkbox:@"True peak (4x oversampled)" get:g set:s
                            tooltip:@"Catch peaks between samples, which can go over 0 dBFS after conversion"]];
    }
    const auto rmsShown = [] { return configInt(kKeyBarMode, kDefaultBarMode) != (int)BarMode::Peak; };
    {
        auto [g, s] = intKey(kKeyRmsMs, kDefaultRmsMs);
        Row r = [self slider:@"RMS window" min:kMinRmsMs max:kMaxRmsMs get:g set:s
                      format:[](int v) { return fmt(@"%d ms", v); } tooltip:@"Time the RMS level is averaged over"];
        r.step = 10;
        r.visible = isDigital;
        r.enabled = rmsShown;
        r.note = [] { return @"Bars show peak only"; };
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeyRmsSinePeak, kDefaultRmsSinePeak);
        Row r = [self checkbox:@"RMS +3 dB (a sine reads its peak level)" get:g set:s
                       tooltip:@"The AES17 convention: a full-scale sine reads 0 dB on both peak and RMS"];
        r.visible = isDigital;
        r.enabled = rmsShown;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyPeakFallTenths, kDefaultPeakFallTenths);
        Row r = [self slider:@"Peak fall" min:kMinPeakFallTenths max:kMaxPeakFallTenths get:g set:s
                      format:[](int v) { return [NSString stringWithFormat:@"%.1f dB/s", v / 10.0]; }
                     tooltip:@"How fast the peak bar falls; 11.8 dB/s is the usual digital meter rate (20 dB in 1.7 s)"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyPeakHoldMs, kDefaultPeakHoldMs);
        Row r = [self slider:@"Peak hold" min:0 max:kMaxPeakHoldMs get:g set:s
                      format:[](int v) { return v == 0 ? @"Off" : [NSString stringWithFormat:@"%.1f s", v / 1000.0]; }
                     tooltip:@"How long the peak marker stays before it falls"];
        r.step = 100;
        r.visible = isDigital;
        r.enabled = [] { return !configBool(kKeyHoldForever, kDefaultHoldForever); };
        r.note = [] { return @"Held until clicked"; };
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeyHoldForever, kDefaultHoldForever);
        Row r = [self checkbox:@"Hold peaks until clicked" get:g set:s tooltip:nil];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    const auto dbfsScale = [] { return digital() && configInt(kKeyScale, kDefaultScale) == (int)ScaleType::Dbfs; };
    {
        auto [g, s] = intKey(kKeyWarnDb, kDefaultWarnDb);
        Row r = [self slider:@"Warning from" min:kMinZoneDb max:0 get:g set:s
                      format:[](int v) { return fmt(@"%d dBFS", v); } tooltip:@"Where the bars turn the warning colour"];
        r.visible = dbfsScale;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyOverDb, kDefaultOverDb);
        Row r = [self slider:@"Over from" min:kMinZoneDb max:0 get:g set:s
                      format:[](int v) { return fmt(@"%d dBFS", v); } tooltip:@"Where the bars turn the over colour"];
        r.visible = dbfsScale;
        [self addRow:std::move(r)];
    }

    // --- Loudness ---
    [self section:@"Loudness" visible:isDigital];
    {
        std::vector<Choice> targets = {
            {@"-9 LUFS (club, loud masters)", -9}, {@"-11 LUFS", -11}, {@"-14 LUFS (streaming)", -14},
            {@"-16 LUFS (podcasts, Apple)", -16}, {@"-18 LUFS", -18}, {@"-23 LUFS (EBU R128)", -23},
            {@"-24 LUFS (ATSC A/85)", -24} };
        auto [g, s] = intKey(kKeyTargetLufs, kDefaultTargetLufs);
        Row r = [self popup:@"Target" choices:targets width:220 get:g set:s
                    tooltip:@"Marker on the loudness bars; readings above it turn the warning colour"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeyResetOnTrack, kDefaultResetOnTrack);
        Row r = [self checkbox:@"Reset integrated loudness on track change" get:g set:s
                       tooltip:@"Off: the measurement runs across tracks until you click the loudness figures"];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }

    // --- Analog ---
    [self section:@"Analog" visible:isAnalog];
    {
        auto [g, s] = intKey(kKeyFace, kDefaultFace);
        Row r = [self popup:@"Face"
                    choices:{{@"Vintage", (int)FaceStyle::Vintage}, {@"Dark", (int)FaceStyle::Dark},
                             {@"Theme colors", (int)FaceStyle::Theme}}
                      width:150 get:g set:s tooltip:nil];
        r.visible = isAnalog;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyNeedleLayout, kDefaultNeedleLayout);
        Row r = [self popup:@"Meters"
                    choices:{{@"Auto", (int)NeedleLayout::Auto}, {@"Two faces", (int)NeedleLayout::Pair},
                             {@"One face, two needles", (int)NeedleLayout::Single}}
                      width:190 get:g set:s
                    tooltip:@"Two faces sit side by side or stacked, whichever gives the bigger faces"];
        r.visible = isAnalog;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyNeedle, kDefaultNeedle);
        Row r = [self popup:@"Ballistics"
                    choices:{{@"VU (300 ms)", (int)NeedleBallistics::VU},
                             {@"PPM, DIN style", (int)NeedleBallistics::PpmDin},
                             {@"PPM, BBC / EBU style", (int)NeedleBallistics::PpmBbc},
                             {@"PPM, Nordic style", (int)NeedleBallistics::PpmNordic}}
                      width:190 get:g set:s
                    tooltip:@"VU averages over 300 ms like a moving-coil meter; PPMs rise fast and fall slowly"];
        r.visible = isAnalog;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyReferenceDb, kDefaultReferenceDb);
        Row r = [self slider:@"Reference" min:kMinReferenceDb max:kMaxReferenceDb get:g set:s
                      format:[](int v) { return fmt(@"0 VU = %d dBFS", v); }
                     tooltip:@"The sine level that reads 0 VU. Lower it for loud modern masters"];
        r.visible = isAnalog;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeyPeakLed, kDefaultPeakLed);
        Row r = [self checkbox:@"Peak LED" get:g set:s tooltip:@"Lights when a peak passes the threshold below"];
        r.visible = isAnalog;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyPeakLedDb, kDefaultPeakLedDb);
        Row r = [self slider:@"Peak LED at" min:kMinPeakLedDb max:0 get:g set:s
                      format:[](int v) { return fmt(@"%d dBFS", v); } tooltip:nil];
        r.visible = isAnalog;
        r.enabled = [] { return configBool(kKeyPeakLed, kDefaultPeakLed); };
        r.note = [] { return @"Peak LED is off"; };
        [self addRow:std::move(r)];
    }

    // --- Appearance ---
    [self section:@"Appearance" visible:nullptr];
    {
        std::vector<Choice> themes;
        for (int index : kMeterThemeMenuOrder) themes.push_back({[NSString stringWithUTF8String:kMeterThemes[index].name], index});
        [self addRow:[self popup:@"Theme" choices:themes width:160
                             get:[] {
                                 const int t = configInt(kKeyTheme, kDefaultMeterTheme);
                                 return t >= 0 && t < kMeterThemeCount ? t : 0;
                             }
                             set:[](int v) {
                                 setConfigInt(kKeyTheme, v);
                                 applyThemeToConfig(v);   // no-op for Custom
                             }
                         tooltip:@"A color preset for the meter's colors (the Vintage and Dark faces keep their own)"]];
    }
    for (int i = 0; i < kColorCount; ++i) [self colorPair:i];
    {
        auto [g, s] = boolKey(kKeyGlass, kDefaultGlass);
        [self addRow:[self checkbox:@"Glass background" get:g set:s tooltip:@"Translucent blur background instead of a solid color"]];
    }
}

- (void)loadValues {
    for (Row &r : _rows) [self loadValueOfRow:r];
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
        case RowKind::ColorPair:
            ((NSColorWell *)r.control).color = [self colorFromARGB:getColor(r.colorIndex, false)];
            r.darkWell.color = [self colorFromARGB:getColor(r.colorIndex, true)];
            break;
    }
}

- (void)refresh {
    CGFloat y = 44;
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
                r.value.stringValue = showNote ? r.note() : r.format(r.get());
                r.value.textColor = showNote ? [NSColor secondaryLabelColor] : [NSColor labelColor];
                y += kRowHeight;
                break;
            }
            case RowKind::Checkbox:
                r.control.frame = NSMakeRect(kLabelX, y, kPageWidth - kLabelX - 10, 20);
                y += kCheckboxHeight;
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
        case RowKind::ColorPair: {
            const bool dark = sender != r.control;
            setConfigInt(dark ? kKeyColorDark[r.colorIndex] : kKeyColorLight[r.colorIndex],
                         [self argbFromColor:((NSColorWell *)sender).color]);
            // A manual color edit means the palette no longer matches a theme.
            setConfigInt(kKeyTheme, 0);
            break;
        }
    }
    // A setting can change others (theme colors) and which rows apply, so
    // reload everything except the control being dragged.
    for (size_t i = 0; i < _rows.size(); ++i) {
        if ((NSInteger)i != sender.tag) [self loadValueOfRow:_rows[i]];
    }
    [self refresh];
    [self notifyChanged];
}

#pragma mark - Helpers

// Stored colours are Display P3, matching how the meter draws them.
- (NSColor *)colorFromARGB:(uint32_t)argb {
    return JLColorFromARGB(argb);
}

- (uint32_t)argbFromColor:(NSColor *)color {
    return JLARGBFromColor(color);
}

- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:kSettingsChangedNotification object:self];
}

- (void)showComponentInfo:(NSButton *)sender {
    JLShowComponentInfo(sender, JLComponentInfoRows());
}

@end

// --- Preferences page registration ---
namespace {
    class levelmeter_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            return fb2k::wrapNSObject([[LevelMeterPreferences alloc] init]);
        }
        const char* get_name() override { return "Level Meter"; }
        GUID get_guid() override { return levelmeter_config::guid_preferences_page; }
        GUID get_parent_guid() override { return preferences_page::guid_display; }
    };
    FB2K_SERVICE_FACTORY(levelmeter_preferences_page);
}
