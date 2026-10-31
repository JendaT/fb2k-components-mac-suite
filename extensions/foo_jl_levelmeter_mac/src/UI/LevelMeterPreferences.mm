//
//  LevelMeterPreferences.mm
//  foo_jl_levelmeter_mac
//
//  Preferences page in the Waveform Seekbar's style: two columns of cards,
//  each setting a heading, its control at full card width and a short hint.
//  Rows that do not apply to the chosen style are hidden (cards with nothing
//  left disappear and the column closes up) or disabled with a note saying
//  why.
//

#import "LevelMeterPreferences.h"
#include "../fb2k_sdk.h"
#include "../Core/LevelMeterConfig.h"
#import "../../../../shared/PreferencesCommon.h"
#import "../../../../shared/ThemeColor.h"
#include "../Integration/ComponentInfo.h"
#include <algorithm>
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

// Same geometry as the Waveform Seekbar's page
constexpr CGFloat kPageWidth = 660.0;
constexpr CGFloat kMargin = 20.0;
constexpr CGFloat kColumnGap = 16.0;
constexpr CGFloat kColumnWidth = (kPageWidth - 2 * kMargin - kColumnGap) / 2;
constexpr CGFloat kCardGap = 16.0;
constexpr CGFloat kCardPad = 14.0;
constexpr CGFloat kRowGap = 12.0;
constexpr CGFloat kHintIndent = 20.0;   // under a checkbox's title
constexpr CGFloat kTop = 42.0;          // below the page title

enum class RowKind { Popup, Slider, Checkbox, ColorPair };

struct Choice {
    NSString *title;
    int value;
};

// One setting. get/set read and write config; the optional blocks decide
// whether the row shows, whether it can be changed, and the note shown in
// place of a slider's value while it cannot.
struct Row {
    RowKind kind = RowKind::Popup;
    int card = 0;
    NSTextField *heading = nil;     // popup / slider title, colour name
    NSControl *control = nil;       // popup, slider, checkbox, or light colour well
    NSColorWell *darkWell = nil;    // colour pair
    NSTextField *value = nil;       // slider value or note
    NSTextField *hint = nil;
    NSTextField *lightCaption = nil, *darkCaption = nil;
    int step = 1;
    std::function<int()> get;
    std::function<void(int)> set;
    std::function<NSString *(int)> format;
    std::function<bool()> visible;
    std::function<bool()> enabled;
    std::function<NSString *()> note;
    int colorIndex = -1;            // colour pair
};

struct Card {
    NSTextField *title = nil;
    NSBox *box = nil;
    int column = 0;
    std::function<bool()> visible;
};

NSString *fmt(NSString *format, int v) { return [NSString stringWithFormat:format, v]; }

int configInt(const char *key, int def) { return (int)getConfigInt(key, def); }
bool configBool(const char *key, bool def) { return getConfigBool(key, def); }

bool digital() { return configInt(kKeyStyle, kDefaultStyle) == (int)MeterStyle::Digital; }
bool analog() { return !digital(); }

void hideViews(std::initializer_list<NSView *> views, bool hidden) {
    for (NSView *v : views) if (v) v.hidden = hidden;
}

} // namespace

@interface LevelMeterPreferences () {
    LevelMeterFlippedView *_page;
    std::vector<Row> _rows;
    std::vector<Card> _cards;
}
@end

@implementation LevelMeterPreferences

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (NSString *)preferencesTitle { return @"Level Meter"; }

- (void)loadView {
    // The cards live in a flipped page inside a scroll view, so a
    // preferences window shorter than the page can scroll.
    _page = [[LevelMeterFlippedView alloc] initWithFrame:NSMakeRect(0, 0, kPageWidth, 600)];
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

#pragma mark - Building blocks

- (NSTextField *)headingWithText:(NSString *)text {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont systemFontOfSize:13];
    [_page addSubview:l];
    return l;
}

- (NSTextField *)smallLabel:(NSString *)text {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont systemFontOfSize:11];
    [_page addSubview:l];
    return l;
}

- (NSTextField *)hintWithText:(NSString *)text {
    if (text.length == 0) return nil;
    NSTextField *h = [NSTextField wrappingLabelWithString:text];
    h.font = [NSFont systemFontOfSize:11];
    h.textColor = [NSColor secondaryLabelColor];
    [_page addSubview:h];
    return h;
}

// Starts a card; the rows added after it belong to it.
- (void)card:(NSString *)title column:(int)column visible:(std::function<bool()>)visible {
    Card c;
    c.column = column;
    c.visible = std::move(visible);
    c.title = [NSTextField labelWithAttributedString:[[NSAttributedString alloc]
        initWithString:title.uppercaseString
            attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                          NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
                          NSKernAttributeName: @0.6 }]];
    [c.title sizeToFit];
    [_page addSubview:c.title];
    c.box = [[NSBox alloc] initWithFrame:NSZeroRect];
    c.box.boxType = NSBoxCustom;
    c.box.titlePosition = NSNoTitle;
    c.box.cornerRadius = 8.0;
    c.box.borderWidth = 1.0;
    c.box.borderColor = [NSColor separatorColor];
    c.box.fillColor = [[NSColor labelColor] colorWithAlphaComponent:0.035];
    [_page addSubview:c.box positioned:NSWindowBelow relativeTo:nil];
    _cards.push_back(std::move(c));
}

- (NSInteger)addRow:(Row)row {
    const NSInteger index = (NSInteger)_rows.size();
    row.card = (int)_cards.size() - 1;
    for (NSControl *c : { row.control, (NSControl *)row.darkWell }) {
        if (!c) continue;
        c.tag = index;
        c.target = self;
        c.action = @selector(rowChanged:);
        [_page addSubview:c];
    }
    _rows.push_back(std::move(row));
    return index;
}

- (Row)popup:(NSString *)title choices:(std::vector<Choice>)choices
         get:(std::function<int()>)get set:(std::function<void(int)>)set hint:(NSString *)hint {
    Row r;
    r.kind = RowKind::Popup;
    r.heading = [self headingWithText:title];
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (const Choice &c : choices) {   // item tags hold the stored value
        [p addItemWithTitle:c.title];
        p.lastItem.tag = c.value;
    }
    r.control = p;
    r.hint = [self hintWithText:hint];
    r.get = std::move(get);
    r.set = std::move(set);
    return r;
}

- (Row)slider:(NSString *)title min:(int)lo max:(int)hi
          get:(std::function<int()>)get set:(std::function<void(int)>)set
       format:(std::function<NSString *(int)>)format hint:(NSString *)hint {
    Row r;
    r.kind = RowKind::Slider;
    r.heading = [self headingWithText:title];
    NSSlider *s = [NSSlider sliderWithValue:lo minValue:lo maxValue:hi target:nil action:nil];
    s.continuous = YES;
    r.control = s;
    r.value = [self headingWithText:@""];
    r.value.alignment = NSTextAlignmentRight;
    r.hint = [self hintWithText:hint];
    r.get = std::move(get);
    r.set = std::move(set);
    r.format = std::move(format);
    return r;
}

- (Row)checkbox:(NSString *)title get:(std::function<int()>)get set:(std::function<void(int)>)set
           hint:(NSString *)hint {
    Row r;
    r.kind = RowKind::Checkbox;
    NSButton *b = [NSButton checkboxWithTitle:title target:nil action:nil];
    b.font = [NSFont systemFontOfSize:13];
    r.control = b;
    r.hint = [self hintWithText:hint];
    r.get = std::move(get);
    r.set = std::move(set);
    return r;
}

- (NSColorWell *)colorWell {
    NSColorWell *w = [[NSColorWell alloc] initWithFrame:NSZeroRect];
    if (@available(macOS 13.0, *)) { w.colorWellStyle = NSColorWellStyleMinimal; }
    return w;
}

- (void)colorPair:(int)index hint:(NSString *)hint {
    Row r;
    r.kind = RowKind::ColorPair;
    r.heading = [self smallLabel:[NSString stringWithUTF8String:kColorNames[index]]];
    r.control = [self colorWell];
    r.darkWell = [self colorWell];
    r.lightCaption = [self smallLabel:@"Light"];
    r.darkCaption = [self smallLabel:@"Dark"];
    r.lightCaption.textColor = r.darkCaption.textColor = [NSColor secondaryLabelColor];
    r.hint = [self hintWithText:hint];
    r.colorIndex = index;
    [self addRow:std::move(r)];
}

#pragma mark - Cards

- (void)buildRows {
    NSTextField *title = JLCreatePreferencesTitle(@"Level Meter");
    title.frame = NSMakeRect(kMargin, 10, 400, 20);
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

    // ---------- Left column ----------

    [self card:@"Display" column:0 visible:nullptr];
    {
        auto [g, s] = intKey(kKeyStyle, kDefaultStyle);
        [self addRow:[self popup:@"Style" choices:{{@"Digital", (int)MeterStyle::Digital}, {@"Analog VU", (int)MeterStyle::Analog}}
                             get:g set:s
                            hint:@"Bars with loudness and stereo figures, or moving-coil needle faces."]];
    }
    {
        auto [g, s] = intKey(kKeyOrientation, kDefaultOrientation);
        Row r = [self popup:@"Orientation"
                    choices:{{@"Auto", (int)Orientation::Auto}, {@"Vertical", (int)Orientation::Vertical},
                             {@"Horizontal", (int)Orientation::Horizontal}}
                        get:g set:s hint:@"Auto runs the bars along the panel's longer side."];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        static NSString *const kSizeNames[] = { @"Small", @"Medium", @"Large", @"Extra large" };
        std::vector<Choice> sizes;
        for (size_t i = 0; i < sizeof(kTextSizes) / sizeof(kTextSizes[0]); ++i) {
            sizes.push_back({[NSString stringWithFormat:@"%@ (%d pt)", kSizeNames[i], kTextSizes[i]], kTextSizes[i]});
        }
        Row r = [self popup:@"Text size" choices:sizes
                        get:[] { return getTextSize(); } set:[](int v) { setConfigInt(kKeyTextSize, v); }
                       hint:@"Readouts, scales, labels and loudness figures."];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyBarMode, kDefaultBarMode);
        Row r = [self popup:@"Bars"
                    choices:{{@"Peak + RMS", (int)BarMode::PeakAndRms}, {@"Peak", (int)BarMode::Peak}, {@"RMS", (int)BarMode::Rms}}
                        get:g set:s hint:@"Peak + RMS: the wide bar is RMS, the slim column above it the peak."];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyScale, kDefaultScale);
        Row r = [self popup:@"Scale"
                    choices:{{@"dBFS", (int)ScaleType::Dbfs}, {@"K-20", (int)ScaleType::K20},
                             {@"K-14", (int)ScaleType::K14}, {@"K-12", (int)ScaleType::K12}}
                        get:g set:s
                       hint:@"K-system: 0 at -20 / -14 / -12 dBFS; green below 0, yellow to +4, red above."];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeySpacing, kDefaultSpacing);
        Row r = [self popup:@"Scale spacing"
                    choices:{{@"Extended top", (int)ScaleSpacing::Extended}, {@"Linear", (int)ScaleSpacing::Linear}}
                        get:g set:s hint:@"Extended gives the top 20 dB half the bar."];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        std::vector<Choice> floors;
        for (int f : kFloorChoices) floors.push_back({fmt(@"%d dB", f), f});
        auto [g, s] = intKey(kKeyFloorDb, kDefaultFloorDb);
        Row r = [self popup:@"Range" choices:floors get:g set:s hint:@"Level at the bottom of the bars."];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeySegments, kDefaultSegments);
        Row r = [self checkbox:@"LED segments" get:g set:s hint:@"Bars split into segments like an LED meter."];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }

    [self card:@"Appearance" column:0 visible:nullptr];
    {
        std::vector<Choice> themes;
        for (int index : kMeterThemeMenuOrder) themes.push_back({[NSString stringWithUTF8String:kMeterThemes[index].name], index});
        [self addRow:[self popup:@"Theme" choices:themes
                             get:[] {
                                 const int t = configInt(kKeyTheme, kDefaultMeterTheme);
                                 return t >= 0 && t < kMeterThemeCount ? t : 0;
                             }
                             set:[](int v) {
                                 setConfigInt(kKeyTheme, v);
                                 applyThemeToConfig(v);   // no-op for Custom
                             }
                            hint:nil]];
    }
    for (int i = 0; i < kColorCount; ++i) {
        [self colorPair:i hint:i == kColorCount - 1
            ? @"Editing a colour switches Theme to Custom. The Vintage and Dark faces keep their own colours."
            : nil];
    }
    {
        auto [g, s] = boolKey(kKeyGlass, kDefaultGlass);
        [self addRow:[self checkbox:@"Glass background" get:g set:s
                               hint:@"Translucent blur behind the meter instead of the background colour."]];
    }

    // ---------- Right column ----------

    [self card:@"Show" column:1 visible:isDigital];
    {
        auto [g, s] = boolKey(kKeyShowReadouts, kDefaultShowReadouts);
        [self addRow:[self checkbox:@"Readouts" get:g set:s
                               hint:@"Highest peak above each bar (click to reset) and the loudness values."]];
    }
    {
        auto [g, s] = boolKey(kKeyShowLoudness, kDefaultShowLoudness);
        [self addRow:[self checkbox:@"Loudness" get:g set:s
                               hint:@"Momentary and short-term bars; integrated, range, true peak and PLR."]];
    }
    [self addRow:[self checkbox:@"Correlation" get:[] { return getShowCorrelation() ? 1 : 0; }
                            set:[](int v) { setConfigBool(kKeyShowCorrelation, v != 0); }
                           hint:@"+1 mono, 0 wide, below 0 out of phase."]];
    [self addRow:[self checkbox:@"Balance" get:[] { return getShowBalance() ? 1 : 0; }
                            set:[](int v) { setConfigBool(kKeyShowBalance, v != 0); }
                           hint:@"Which channel is louder; full scale at 12 dB."]];

    [self card:@"Levels" column:1 visible:nullptr];
    {
        auto [g, s] = boolKey(kKeyTruePeak, kDefaultTruePeak);
        [self addRow:[self checkbox:@"True peak (4x oversampled)" get:g set:s
                               hint:@"Catches peaks between samples, which can pass 0 dBFS after conversion."]];
    }
    const auto rmsShown = [] { return configInt(kKeyBarMode, kDefaultBarMode) != (int)BarMode::Peak; };
    {
        auto [g, s] = intKey(kKeyRmsMs, kDefaultRmsMs);
        Row r = [self slider:@"RMS window" min:kMinRmsMs max:kMaxRmsMs get:g set:s
                      format:[](int v) { return fmt(@"%d ms", v); } hint:nil];
        r.step = 10;
        r.visible = isDigital;
        r.enabled = rmsShown;
        r.note = [] { return @"Bars show peak only"; };
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeyRmsSinePeak, kDefaultRmsSinePeak);
        Row r = [self checkbox:@"RMS +3 dB" get:g set:s
                          hint:@"A full-scale sine reads 0 dB on both peak and RMS (AES17)."];
        r.visible = isDigital;
        r.enabled = rmsShown;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyPeakFallTenths, kDefaultPeakFallTenths);
        Row r = [self slider:@"Peak fall" min:kMinPeakFallTenths max:kMaxPeakFallTenths get:g set:s
                      format:[](int v) { return [NSString stringWithFormat:@"%.1f dB/s", v / 10.0]; }
                        hint:@"11.8 dB/s is the usual digital meter rate (20 dB in 1.7 s)."];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyPeakHoldMs, kDefaultPeakHoldMs);
        Row r = [self slider:@"Peak hold" min:0 max:kMaxPeakHoldMs get:g set:s
                      format:[](int v) { return v == 0 ? @"Off" : [NSString stringWithFormat:@"%.1f s", v / 1000.0]; }
                        hint:nil];
        r.step = 100;
        r.visible = isDigital;
        r.enabled = [] { return !configBool(kKeyHoldForever, kDefaultHoldForever); };
        r.note = [] { return @"Held until clicked"; };
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeyHoldForever, kDefaultHoldForever);
        Row r = [self checkbox:@"Hold peaks until clicked" get:g set:s hint:nil];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = boolKey(kKeyResetPeaksOnTrack, kDefaultResetPeaksOnTrack);
        Row r = [self checkbox:@"Reset peaks on track change" get:g set:s
                          hint:@"Clears maxima and clip lights; off keeps overs latched until you click the bars."];
        r.visible = isDigital;
        [self addRow:std::move(r)];
    }
    const auto dbfsScale = [] { return digital() && configInt(kKeyScale, kDefaultScale) == (int)ScaleType::Dbfs; };
    {
        auto [g, s] = intKey(kKeyWarnDb, kDefaultWarnDb);
        Row r = [self slider:@"Warning from" min:kMinZoneDb max:0 get:g set:s
                      format:[](int v) { return fmt(@"%d dBFS", v); } hint:nil];
        r.visible = dbfsScale;
        [self addRow:std::move(r)];
    }
    {
        auto [g, s] = intKey(kKeyOverDb, kDefaultOverDb);
        Row r = [self slider:@"Over from" min:kMinZoneDb max:0 get:g set:s
                      format:[](int v) { return fmt(@"%d dBFS", v); }
                        hint:@"Where the bars turn the warning and over colours (dBFS scale)."];
        r.visible = dbfsScale;
        [self addRow:std::move(r)];
    }

    [self card:@"Loudness" column:1 visible:isDigital];
    {
        std::vector<Choice> targets = {
            {@"-9 LUFS (club, loud masters)", -9}, {@"-11 LUFS", -11}, {@"-14 LUFS (streaming)", -14},
            {@"-16 LUFS (podcasts, Apple)", -16}, {@"-18 LUFS", -18}, {@"-23 LUFS (EBU R128)", -23},
            {@"-24 LUFS (ATSC A/85)", -24} };
        auto [g, s] = intKey(kKeyTargetLufs, kDefaultTargetLufs);
        [self addRow:[self popup:@"Target" choices:targets get:g set:s
                            hint:@"Marker on the loudness bars; readings above it turn the warning colour."]];
    }
    {
        auto [g, s] = boolKey(kKeyResetOnTrack, kDefaultResetOnTrack);
        [self addRow:[self checkbox:@"Reset on track change" get:g set:s
                               hint:@"Off: the measurement runs across tracks until you click the figures."]];
    }

    [self card:@"Analog" column:1 visible:isAnalog];
    {
        auto [g, s] = intKey(kKeyFace, kDefaultFace);
        [self addRow:[self popup:@"Face"
                         choices:{{@"Vintage", (int)FaceStyle::Vintage}, {@"Dark", (int)FaceStyle::Dark},
                                  {@"Theme colours", (int)FaceStyle::Theme}}
                             get:g set:s hint:nil]];
    }
    {
        auto [g, s] = intKey(kKeyNeedleLayout, kDefaultNeedleLayout);
        [self addRow:[self popup:@"Meters"
                         choices:{{@"Auto", (int)NeedleLayout::Auto}, {@"Two faces", (int)NeedleLayout::Pair},
                                  {@"One face, two needles", (int)NeedleLayout::Single}}
                             get:g set:s hint:@"Auto puts two faces side by side or stacked, whichever is bigger."]];
    }
    {
        auto [g, s] = intKey(kKeyNeedle, kDefaultNeedle);
        [self addRow:[self popup:@"Ballistics"
                         choices:{{@"VU (300 ms)", (int)NeedleBallistics::VU},
                                  {@"PPM, DIN style", (int)NeedleBallistics::PpmDin},
                                  {@"PPM, BBC / EBU style", (int)NeedleBallistics::PpmBbc},
                                  {@"PPM, Nordic style", (int)NeedleBallistics::PpmNordic}}
                             get:g set:s hint:@"VU averages over 300 ms; PPMs rise fast and fall slowly."]];
    }
    {
        auto [g, s] = intKey(kKeyReferenceDb, kDefaultReferenceDb);
        [self addRow:[self slider:@"Reference" min:kMinReferenceDb max:kMaxReferenceDb get:g set:s
                           format:[](int v) { return fmt(@"0 VU = %d dBFS", v); }
                             hint:@"The sine level that reads 0 VU. Around -10 dBFS suits loud modern masters."]];
    }
    {
        auto [g, s] = boolKey(kKeyPeakLed, kDefaultPeakLed);
        [self addRow:[self checkbox:@"Peak LED" get:g set:s hint:nil]];
    }
    {
        auto [g, s] = intKey(kKeyPeakLedDb, kDefaultPeakLedDb);
        Row r = [self slider:@"Peak LED at" min:kMinPeakLedDb max:0 get:g set:s
                      format:[](int v) { return fmt(@"%d dBFS", v); } hint:nil];
        r.enabled = [] { return configBool(kKeyPeakLed, kDefaultPeakLed); };
        r.note = [] { return @"Peak LED is off"; };
        [self addRow:std::move(r)];
    }
}

#pragma mark - Values

- (void)loadValues {
    for (Row &r : _rows) [self loadValueOfRow:r];
}

- (void)loadValueOfRow:(Row &)r {
    switch (r.kind) {
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

#pragma mark - Layout

// Places a hint below the current row and returns its height.
- (CGFloat)placeHint:(NSTextField *)hint x:(CGFloat)x y:(CGFloat)y width:(CGFloat)w {
    if (!hint) return 0;
    hint.preferredMaxLayoutWidth = w;
    const CGFloat h = [hint.cell cellSizeForBounds:NSMakeRect(0, 0, w, 1000)].height;
    hint.frame = NSMakeRect(x, y, w, h);
    return h;
}

// Lays out one row from y and returns the y below it.
- (CGFloat)layoutRow:(Row &)r x:(CGFloat)x y:(CGFloat)y width:(CGFloat)w {
    const bool enabled = !r.enabled || r.enabled();
    switch (r.kind) {
        case RowKind::Popup:
            r.heading.frame = NSMakeRect(x, y, w, 17);
            y += 21;
            r.control.frame = NSMakeRect(x - 2, y, w + 4, 26);
            y += 30;
            y += [self placeHint:r.hint x:x y:y width:w];
            y += kRowGap;
            break;
        case RowKind::Slider: {
            r.heading.frame = NSMakeRect(x, y, w * 0.5, 17);
            // While disabled the value gives way to a note saying why.
            const bool showNote = !enabled && r.note;
            r.value.stringValue = showNote ? r.note() : r.format(r.get());
            r.value.textColor = [NSColor secondaryLabelColor];
            r.value.frame = NSMakeRect(x + w * 0.4, y, w * 0.6, 17);
            y += 21;
            r.control.frame = NSMakeRect(x, y, w, 22);
            y += 26;
            y += [self placeHint:r.hint x:x y:y width:w];
            y += kRowGap;
            break;
        }
        case RowKind::Checkbox:
            r.control.frame = NSMakeRect(x, y, w, 18);
            y += 21;
            if (r.hint) {
                y += [self placeHint:r.hint x:x + kHintIndent y:y width:w - kHintIndent];
            }
            y += kRowGap;
            break;
        case RowKind::ColorPair:
            r.heading.frame = NSMakeRect(x, y + 4, 80, 15);
            r.control.frame = NSMakeRect(x + 84, y, 36, 22);
            r.lightCaption.frame = NSMakeRect(x + 124, y + 4, 40, 15);
            r.darkWell.frame = NSMakeRect(x + 168, y, 36, 22);
            r.darkCaption.frame = NSMakeRect(x + 208, y + 4, 40, 15);
            y += 28;
            // The last pair carries the colours' hint and closes the group.
            if (r.hint) {
                y += [self placeHint:r.hint x:x y:y width:w];
                y += kRowGap;
            }
            break;
    }
    r.control.enabled = enabled;
    if (r.darkWell) r.darkWell.enabled = enabled;
    return y;
}

- (void)refresh {
    const CGFloat columnX[2] = { kMargin, kMargin + kColumnWidth + kColumnGap };
    CGFloat columnY[2] = { kTop, kTop };

    for (size_t c = 0; c < _cards.size(); ++c) {
        Card &card = _cards[c];
        const bool cardShown = !card.visible || card.visible();
        bool anyRow = false;
        for (Row &r : _rows) {
            const bool shown = cardShown && r.card == (int)c && (!r.visible || r.visible());
            if (r.card != (int)c) continue;
            hideViews({ r.heading, r.control, r.darkWell, r.value, r.hint, r.lightCaption, r.darkCaption }, !shown);
            anyRow = anyRow || shown;
        }
        hideViews({ card.title, card.box }, !anyRow);
        if (!anyRow) continue;

        const CGFloat top = columnY[card.column];
        const CGFloat x = columnX[card.column] + kCardPad, w = kColumnWidth - 2 * kCardPad;
        CGFloat y = top + kCardPad;
        card.title.frameOrigin = NSMakePoint(x, y);
        y += card.title.frame.size.height + 10;
        for (Row &r : _rows) {
            if (r.card != (int)c || r.control.hidden) continue;
            y = [self layoutRow:r x:x y:y width:w];
        }
        y -= kRowGap;   // the last row's gap becomes the card's padding
        card.box.frame = NSMakeRect(columnX[card.column], top, kColumnWidth, y + kCardPad - top);
        columnY[card.column] = NSMaxY(card.box.frame) + kCardGap;
    }
    const CGFloat bottom = std::max(columnY[0], columnY[1]) - kCardGap + kMargin;
    [_page setFrameSize:NSMakeSize(kPageWidth, bottom)];
}

#pragma mark - Changes

- (void)rowChanged:(NSControl *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)_rows.size()) return;
    Row &r = _rows[(size_t)sender.tag];
    switch (r.kind) {
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
            // A manual colour edit means the palette no longer matches a theme.
            setConfigInt(kKeyTheme, 0);
            break;
        }
    }
    // A setting can change others (theme colours) and which rows apply, so
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
