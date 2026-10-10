//
//  VectorscopePreferences.mm
//  foo_jl_vectorscope_mac
//

#import "VectorscopePreferences.h"
#include "../fb2k_sdk.h"
#include "../Core/VectorscopeConfig.h"
#include "../Core/VectorscopeThemes.h"
#import "../../../../shared/PreferencesCommon.h"

// Uniquely-named flipped view (avoids ObjC runtime clashes across components)
@interface VectorscopeFlippedView : NSView
@end
@implementation VectorscopeFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface VectorscopePreferences () {
    NSPopUpButton *_drawModePopup;
    NSSlider      *_persistenceSlider;
    NSTextField   *_persistenceLabel;
    NSSlider      *_brightnessSlider;
    NSTextField   *_brightnessLabel;
    NSButton      *_autoGainCheckbox;
    NSSlider      *_gainSlider;
    NSTextField   *_gainLabel;
    NSButton      *_correlationCheckbox;
    NSPopUpButton *_correlationModePopup;
    NSSlider      *_integrationSlider;
    NSTextField   *_integrationLabel;
    NSTextField   *_lowHzField;
    NSTextField   *_highHzField;
    NSPopUpButton *_themePopup;
    NSButton      *_gridCheckbox;
    NSButton      *_labelsCheckbox;
    NSButton      *_glassCheckbox;
    NSSlider      *_gridOpacitySlider;
    NSTextField   *_gridOpacityLabel;
    NSColorWell   *_traceColorLightWell;
    NSColorWell   *_bgColorLightWell;
    NSColorWell   *_gridColorLightWell;
    NSColorWell   *_traceColorDarkWell;
    NSColorWell   *_bgColorDarkWell;
    NSColorWell   *_gridColorDarkWell;
}
@end

@implementation VectorscopePreferences

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (NSString *)preferencesTitle { return @"Vectorscope"; }

- (void)loadView {
    VectorscopeFlippedView *view = [[VectorscopeFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 460, 640)];
    self.view = view;
    [NSColor setIgnoresAlpha:NO];
    [NSColorPanel sharedColorPanel].showsAlpha = YES;
    [self buildUI];
    [self loadSettings];
}

- (void)buildUI {
    using namespace vectorscope_config;
    CGFloat y = 10;
    const CGFloat labelX = 20;
    const CGFloat controlX = 150;

    NSTextField *title = JLCreatePreferencesTitle(@"Vectorscope");
    title.frame = NSMakeRect(labelX, y, 400, 20);
    [self.view addSubview:title];
    y += 30;

    // --- Scope section ---
    NSTextField *scopeHeader = JLCreateSectionHeader(@"Scope");
    scopeHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:scopeHeader];
    y += 22;

    [self.view addSubview:[self label:@"Trace:" at:NSMakePoint(labelX + 10, y + 3)]];
    _drawModePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 130, 25)];
    [_drawModePopup addItemWithTitle:@"Lines"];
    [_drawModePopup addItemWithTitle:@"Dots"];
    _drawModePopup.toolTip = @"Lines join the samples and draw fast movement dimmer, like an oscilloscope tube";
    _drawModePopup.target = self; _drawModePopup.action = @selector(drawModeChanged:);
    [self.view addSubview:_drawModePopup];
    y += 30;

    [self.view addSubview:[self label:@"Afterglow:" at:NSMakePoint(labelX + 10, y + 3)]];
    _persistenceSlider = [self sliderAt:NSMakePoint(controlX, y) min:kMinPersistenceMs max:kMaxPersistenceMs
                                 action:@selector(persistenceChanged:)];
    _persistenceSlider.toolTip = @"How long the trace takes to fade";
    [self.view addSubview:_persistenceSlider];
    _persistenceLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_persistenceLabel];
    y += 30;

    [self.view addSubview:[self label:@"Brightness:" at:NSMakePoint(labelX + 10, y + 3)]];
    _brightnessSlider = [self sliderAt:NSMakePoint(controlX, y) min:0 max:100 action:@selector(brightnessChanged:)];
    [self.view addSubview:_brightnessSlider];
    _brightnessLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_brightnessLabel];
    y += 30;

    _autoGainCheckbox = [self checkbox:@"Auto gain" at:NSMakePoint(labelX + 10, y)];
    _autoGainCheckbox.toolTip = @"Scale the picture so quiet and loud tracks both fill the scope";
    [self.view addSubview:_autoGainCheckbox];
    y += 26;

    [self.view addSubview:[self label:@"Gain:" at:NSMakePoint(labelX + 10, y + 3)]];
    _gainSlider = [self sliderAt:NSMakePoint(controlX, y) min:0 max:kMaxGainDb action:@selector(gainChanged:)];
    _gainSlider.toolTip = @"Fixed gain used when auto gain is off (0 dB: full scale touches the diamond)";
    [self.view addSubview:_gainSlider];
    _gainLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_gainLabel];
    y += 34;

    // --- Correlation section ---
    NSTextField *corrHeader = JLCreateSectionHeader(@"Correlation Meter");
    corrHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:corrHeader];
    y += 22;

    _correlationCheckbox = [self checkbox:@"Show correlation meter" at:NSMakePoint(labelX + 10, y)];
    _correlationCheckbox.toolTip = @"+1 = mono, 0 = wide or unrelated, below 0 = out of phase";
    [self.view addSubview:_correlationCheckbox];
    y += 26;

    [self.view addSubview:[self label:@"Bands:" at:NSMakePoint(labelX + 10, y + 3)]];
    _correlationModePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 160, 25)];
    [_correlationModePopup addItemWithTitle:@"Single"];
    [_correlationModePopup addItemWithTitle:@"Low / Mid / High"];
    _correlationModePopup.toolTip = @"Three bands show which part of the spectrum is out of phase";
    _correlationModePopup.target = self; _correlationModePopup.action = @selector(correlationModeChanged:);
    [self.view addSubview:_correlationModePopup];
    y += 30;

    [self.view addSubview:[self label:@"Response time:" at:NSMakePoint(labelX + 10, y + 3)]];
    _integrationSlider = [self sliderAt:NSMakePoint(controlX, y) min:kMinIntegrationMs max:kMaxIntegrationMs
                                 action:@selector(integrationChanged:)];
    _integrationSlider.toolTip = @"Time window the reading is averaged over";
    [self.view addSubview:_integrationSlider];
    _integrationLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_integrationLabel];
    y += 30;

    [self.view addSubview:[self label:@"Crossovers (Hz):" at:NSMakePoint(labelX + 10, y + 3)]];
    _lowHzField = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX, y, 70, 22)];
    _lowHzField.formatter = [self intFormatterMin:kMinLowHz max:kMaxLowHz];
    _lowHzField.toolTip = @"Low / mid split";
    _lowHzField.target = self; _lowHzField.action = @selector(crossoverChanged:);
    [self.view addSubview:_lowHzField];
    [self.view addSubview:[self label:@"and" at:NSMakePoint(controlX + 76, y + 3)]];
    _highHzField = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX + 104, y, 70, 22)];
    _highHzField.formatter = [self intFormatterMin:kMinHighHz max:kMaxHighHz];
    _highHzField.toolTip = @"Mid / high split";
    _highHzField.target = self; _highHzField.action = @selector(crossoverChanged:);
    [self.view addSubview:_highHzField];
    y += 34;

    // --- Appearance section ---
    NSTextField *appearanceHeader = JLCreateSectionHeader(@"Appearance");
    appearanceHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:appearanceHeader];
    y += 22;

    [self.view addSubview:[self label:@"Theme:" at:NSMakePoint(labelX + 10, y + 3)]];
    _themePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 200, 25)];
    for (int i = 0; i < kThemeCount; ++i) {
        [_themePopup addItemWithTitle:[NSString stringWithUTF8String:kThemes[i].name]];
    }
    _themePopup.target = self; _themePopup.action = @selector(themeChanged:);
    _themePopup.toolTip = @"Apply a color preset to trace, background, and grid";
    [self.view addSubview:_themePopup];
    y += 30;

    _gridCheckbox = [self checkbox:@"Show grid" at:NSMakePoint(labelX + 10, y)];
    _gridCheckbox.toolTip = @"Full-scale diamond, mid / side axes and left / right diagonals";
    [self.view addSubview:_gridCheckbox];
    y += 26;

    _labelsCheckbox = [self checkbox:@"Show labels" at:NSMakePoint(labelX + 10, y)];
    _labelsCheckbox.toolTip = @"L / R / M / S around the scope and the scale under the correlation meter";
    [self.view addSubview:_labelsCheckbox];
    y += 26;

    _glassCheckbox = [self checkbox:@"Glass background" at:NSMakePoint(labelX + 10, y)];
    _glassCheckbox.toolTip = @"Translucent blur background instead of a solid color";
    [self.view addSubview:_glassCheckbox];
    y += 30;

    [self.view addSubview:[self label:@"Grid opacity:" at:NSMakePoint(labelX + 10, y + 3)]];
    _gridOpacitySlider = [self sliderAt:NSMakePoint(controlX, y) min:0 max:100 action:@selector(gridOpacityChanged:)];
    [self.view addSubview:_gridOpacitySlider];
    _gridOpacityLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_gridOpacityLabel];
    y += 34;

    // Colors - light
    [self.view addSubview:[self label:@"Colors (Light Mode)" at:NSMakePoint(labelX, y)]];
    y += 22;
    [self addColorRowAt:y trace:&_traceColorLightWell background:&_bgColorLightWell grid:&_gridColorLightWell];
    y += 32;

    // Colors - dark
    [self.view addSubview:[self label:@"Colors (Dark Mode)" at:NSMakePoint(labelX, y)]];
    y += 22;
    [self addColorRowAt:y trace:&_traceColorDarkWell background:&_bgColorDarkWell grid:&_gridColorDarkWell];
    y += 32;
}

- (void)addColorRowAt:(CGFloat)y
                trace:(NSColorWell * __strong *)trace
           background:(NSColorWell * __strong *)background
                 grid:(NSColorWell * __strong *)grid {
    const CGFloat x = 30;
    [self.view addSubview:[self label:@"Trace:" at:NSMakePoint(x, y + 3)]];
    *trace = [self colorWellAt:NSMakePoint(x + 42, y)];
    [self.view addSubview:*trace];
    [self.view addSubview:[self label:@"Background:" at:NSMakePoint(x + 104, y + 3)]];
    *background = [self colorWellAt:NSMakePoint(x + 178, y)];
    [self.view addSubview:*background];
    [self.view addSubview:[self label:@"Grid:" at:NSMakePoint(x + 240, y + 3)]];
    *grid = [self colorWellAt:NSMakePoint(x + 274, y)];
    [self.view addSubview:*grid];
}

#pragma mark - Control factory helpers

- (NSTextField *)label:(NSString *)text at:(NSPoint)p {
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSMakeRect(p.x, p.y, 200, 17)];
    l.stringValue = text; l.editable = NO; l.bordered = NO;
    l.backgroundColor = [NSColor clearColor];
    l.font = [NSFont systemFontOfSize:11];
    [l sizeToFit];
    return l;
}

- (NSTextField *)valueLabelAt:(NSPoint)p {
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSMakeRect(p.x, p.y, 60, 17)];
    l.editable = NO; l.bordered = NO;
    l.backgroundColor = [NSColor clearColor];
    l.font = [NSFont systemFontOfSize:11];
    return l;
}

- (NSSlider *)sliderAt:(NSPoint)p min:(double)lo max:(double)hi action:(SEL)action {
    NSSlider *s = [[NSSlider alloc] initWithFrame:NSMakeRect(p.x, p.y, 150, 22)];
    s.minValue = lo; s.maxValue = hi; s.continuous = YES;
    s.target = self; s.action = action;
    return s;
}

- (NSButton *)checkbox:(NSString *)title at:(NSPoint)p {
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(p.x, p.y, 260, 20)];
    b.buttonType = NSButtonTypeSwitch;
    b.title = title;
    b.target = self; b.action = @selector(checkboxChanged:);
    return b;
}

- (NSColorWell *)colorWellAt:(NSPoint)p {
    NSColorWell *w = [[NSColorWell alloc] initWithFrame:NSMakeRect(p.x, p.y, 40, 24)];
    w.target = self; w.action = @selector(colorChanged:);
    if (@available(macOS 13.0, *)) { w.colorWellStyle = NSColorWellStyleMinimal; }
    return w;
}

- (NSNumberFormatter *)intFormatterMin:(int)lo max:(int)hi {
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    f.numberStyle = NSNumberFormatterNoStyle;
    f.minimum = @(lo); f.maximum = @(hi);
    f.allowsFloats = NO;
    return f;
}

#pragma mark - Load / persist

- (void)loadSettings {
    using namespace vectorscope_config;

    [self selectIndexPopup:_drawModePopup index:getConfigInt(kKeyDrawMode, kDefaultDrawMode)];
    [self selectIndexPopup:_correlationModePopup index:getConfigInt(kKeyCorrelationMode, kDefaultCorrelationMode)];

    int persistence = getConfigIntClamped(kKeyPersistenceMs, kDefaultPersistenceMs, kMinPersistenceMs, kMaxPersistenceMs);
    _persistenceSlider.integerValue = persistence;
    _persistenceLabel.stringValue = [NSString stringWithFormat:@"%dms", persistence];

    int brightness = getConfigIntClamped(kKeyBrightness, kDefaultBrightness, 0, 100);
    _brightnessSlider.integerValue = brightness;
    _brightnessLabel.stringValue = [NSString stringWithFormat:@"%d%%", brightness];

    int gain = getConfigIntClamped(kKeyGainDb, kDefaultGainDb, 0, kMaxGainDb);
    _gainSlider.integerValue = gain;
    _gainLabel.stringValue = [NSString stringWithFormat:@"+%ddB", gain];

    int integration = getConfigIntClamped(kKeyIntegrationMs, kDefaultIntegrationMs, kMinIntegrationMs, kMaxIntegrationMs);
    _integrationSlider.integerValue = integration;
    _integrationLabel.stringValue = [NSString stringWithFormat:@"%dms", integration];

    _lowHzField.integerValue = getConfigIntClamped(kKeyLowHz, kDefaultLowHz, kMinLowHz, kMaxLowHz);
    _highHzField.integerValue = getConfigIntClamped(kKeyHighHz, kDefaultHighHz, kMinHighHz, kMaxHighHz);

    int gridOpacity = getConfigIntClamped(kKeyGridOpacity, kDefaultGridOpacity, 0, 100);
    _gridOpacitySlider.integerValue = gridOpacity;
    _gridOpacityLabel.stringValue = [NSString stringWithFormat:@"%d%%", gridOpacity];

    _autoGainCheckbox.state = getConfigBool(kKeyAutoGain, kDefaultAutoGain) ? NSControlStateValueOn : NSControlStateValueOff;
    _correlationCheckbox.state = getConfigBool(kKeyShowCorrelation, kDefaultShowCorrelation) ? NSControlStateValueOn : NSControlStateValueOff;
    _gridCheckbox.state = getConfigBool(kKeyShowGrid, kDefaultShowGrid) ? NSControlStateValueOn : NSControlStateValueOff;
    _labelsCheckbox.state = getConfigBool(kKeyShowLabels, kDefaultShowLabels) ? NSControlStateValueOn : NSControlStateValueOff;
    _glassCheckbox.state = getConfigBool(kKeyGlassBackground, kDefaultGlassBackground) ? NSControlStateValueOn : NSControlStateValueOff;

    int theme = (int)getConfigInt(kKeyTheme, kDefaultTheme);
    if (theme < 0 || theme >= kThemeCount) theme = 0;
    [_themePopup selectItemAtIndex:theme];

    [self reloadColorWells];
    [self updateEnabledStates];
}

- (void)reloadColorWells {
    using namespace vectorscope_config;
    _traceColorLightWell.color = [self colorFromARGB:(uint32_t)getConfigInt(kKeyTraceColorLight, kDefaultTraceColorLight)];
    _bgColorLightWell.color    = [self colorFromARGB:(uint32_t)getConfigInt(kKeyBgColorLight, kDefaultBgColorLight)];
    _gridColorLightWell.color  = [self colorFromARGB:(uint32_t)getConfigInt(kKeyGridColorLight, kDefaultGridColorLight)];
    _traceColorDarkWell.color  = [self colorFromARGB:(uint32_t)getConfigInt(kKeyTraceColorDark, kDefaultTraceColorDark)];
    _bgColorDarkWell.color     = [self colorFromARGB:(uint32_t)getConfigInt(kKeyBgColorDark, kDefaultBgColorDark)];
    _gridColorDarkWell.color   = [self colorFromARGB:(uint32_t)getConfigInt(kKeyGridColorDark, kDefaultGridColorDark)];
}

// Grey out controls that have no effect in the current setup.
- (void)updateEnabledStates {
    const BOOL autoGain = _autoGainCheckbox.state == NSControlStateValueOn;
    _gainSlider.enabled = !autoGain;

    const BOOL corr = _correlationCheckbox.state == NSControlStateValueOn;
    const BOOL bands = corr && _correlationModePopup.indexOfSelectedItem == vectorscope_config::CorrelationBands;
    _correlationModePopup.enabled = corr;
    _integrationSlider.enabled = corr;
    _lowHzField.enabled = bands;
    _highHzField.enabled = bands;
}

// Config values index these popups directly; an out-of-range value from a
// corrupted config store would raise NSRangeException, so clamp first.
- (void)selectIndexPopup:(NSPopUpButton *)popup index:(NSInteger)idx {
    if (idx < 0 || idx >= popup.numberOfItems) idx = 0;
    [popup selectItemAtIndex:idx];
}

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

- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:vectorscope_config::kSettingsChangedNotification object:nil];
}

#pragma mark - Actions

- (void)drawModeChanged:(id)sender {
    vectorscope_config::setConfigInt(vectorscope_config::kKeyDrawMode, _drawModePopup.indexOfSelectedItem);
    [self notifyChanged];
}

- (void)persistenceChanged:(id)sender {
    int v = (int)_persistenceSlider.integerValue;
    vectorscope_config::setConfigInt(vectorscope_config::kKeyPersistenceMs, v);
    _persistenceLabel.stringValue = [NSString stringWithFormat:@"%dms", v];
    [self notifyChanged];
}

- (void)brightnessChanged:(id)sender {
    int v = (int)_brightnessSlider.integerValue;
    vectorscope_config::setConfigInt(vectorscope_config::kKeyBrightness, v);
    _brightnessLabel.stringValue = [NSString stringWithFormat:@"%d%%", v];
    [self notifyChanged];
}

- (void)gainChanged:(id)sender {
    int v = (int)_gainSlider.integerValue;
    vectorscope_config::setConfigInt(vectorscope_config::kKeyGainDb, v);
    _gainLabel.stringValue = [NSString stringWithFormat:@"+%ddB", v];
    [self notifyChanged];
}

- (void)correlationModeChanged:(id)sender {
    vectorscope_config::setConfigInt(vectorscope_config::kKeyCorrelationMode, _correlationModePopup.indexOfSelectedItem);
    [self updateEnabledStates];
    [self notifyChanged];
}

- (void)integrationChanged:(id)sender {
    int v = (int)_integrationSlider.integerValue;
    vectorscope_config::setConfigInt(vectorscope_config::kKeyIntegrationMs, v);
    _integrationLabel.stringValue = [NSString stringWithFormat:@"%dms", v];
    [self notifyChanged];
}

- (void)crossoverChanged:(id)sender {
    using namespace vectorscope_config;
    setConfigInt(kKeyLowHz, _lowHzField.intValue);
    setConfigInt(kKeyHighHz, _highHzField.intValue);
    [self notifyChanged];
}

- (void)checkboxChanged:(id)sender {
    using namespace vectorscope_config;
    const bool on = ((NSButton *)sender).state == NSControlStateValueOn;
    if (sender == _autoGainCheckbox)         setConfigBool(kKeyAutoGain, on);
    else if (sender == _correlationCheckbox) setConfigBool(kKeyShowCorrelation, on);
    else if (sender == _gridCheckbox)        setConfigBool(kKeyShowGrid, on);
    else if (sender == _labelsCheckbox)      setConfigBool(kKeyShowLabels, on);
    else if (sender == _glassCheckbox)       setConfigBool(kKeyGlassBackground, on);
    [self updateEnabledStates];
    [self notifyChanged];
}

- (void)themeChanged:(id)sender {
    using namespace vectorscope_config;
    NSInteger idx = _themePopup.indexOfSelectedItem;
    setConfigInt(kKeyTheme, idx);
    if (idx > 0) {
        applyThemeToConfig((int)idx);
        [self reloadColorWells];
    }
    [self notifyChanged];
}

- (void)gridOpacityChanged:(id)sender {
    int v = (int)_gridOpacitySlider.integerValue;
    vectorscope_config::setConfigInt(vectorscope_config::kKeyGridOpacity, v);
    _gridOpacityLabel.stringValue = [NSString stringWithFormat:@"%d%%", v];
    [self notifyChanged];
}

- (void)colorChanged:(id)sender {
    using namespace vectorscope_config;
    if (sender == _traceColorLightWell)      setConfigInt(kKeyTraceColorLight, [self argbFromColor:_traceColorLightWell.color]);
    else if (sender == _bgColorLightWell)    setConfigInt(kKeyBgColorLight, [self argbFromColor:_bgColorLightWell.color]);
    else if (sender == _gridColorLightWell)  setConfigInt(kKeyGridColorLight, [self argbFromColor:_gridColorLightWell.color]);
    else if (sender == _traceColorDarkWell)  setConfigInt(kKeyTraceColorDark, [self argbFromColor:_traceColorDarkWell.color]);
    else if (sender == _bgColorDarkWell)     setConfigInt(kKeyBgColorDark, [self argbFromColor:_bgColorDarkWell.color]);
    else if (sender == _gridColorDarkWell)   setConfigInt(kKeyGridColorDark, [self argbFromColor:_gridColorDarkWell.color]);
    // A manual color edit means the palette no longer matches a preset.
    setConfigInt(kKeyTheme, 0);
    [_themePopup selectItemAtIndex:0];
    [self notifyChanged];
}

@end

// --- Preferences page registration ---
namespace {
    class vectorscope_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            return fb2k::wrapNSObject([[VectorscopePreferences alloc] init]);
        }
        const char* get_name() override { return "Vectorscope"; }
        GUID get_guid() override { return vectorscope_config::guid_preferences_page; }
        GUID get_parent_guid() override { return preferences_page::guid_display; }
    };
    FB2K_SERVICE_FACTORY(vectorscope_preferences_page);
}
