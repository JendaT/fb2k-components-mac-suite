//
//  SpectrumPreferences.mm
//  foo_jl_spectrum_mac
//

#import "SpectrumPreferences.h"
#include "../fb2k_sdk.h"
#include "../Core/SpectrumConfig.h"
#include "../Core/SpectrumThemes.h"
#import "../../../../shared/PreferencesCommon.h"

// Uniquely-named flipped view (avoids ObjC runtime clashes across components)
@interface SpectrumFlippedView : NSView
@end
@implementation SpectrumFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface SpectrumPreferences () {
    NSPopUpButton *_themePopup;
    NSPopUpButton *_drawModePopup;
    NSPopUpButton *_orientationPopup;
    NSPopUpButton *_barCountPopup;
    NSPopUpButton *_fftSizePopup;
    NSPopUpButton *_barStylePopup;
    NSPopUpButton *_freqScalePopup;
    NSTextField   *_minHzField;
    NSTextField   *_maxHzField;
    NSSlider      *_gapSlider;
    NSTextField   *_gapLabel;
    NSSlider      *_smoothingSlider;
    NSTextField   *_smoothingLabel;
    NSSlider      *_shadowFallSlider;
    NSTextField   *_shadowFallLabel;
    NSSlider      *_peakFallSlider;
    NSTextField   *_peakFallLabel;
    NSSlider      *_peakHoldSlider;
    NSTextField   *_peakHoldLabel;
    NSButton      *_peakHoldCheckbox;
    NSButton      *_shadowFillCheckbox;
    NSButton      *_dbGuidesCheckbox;
    NSButton      *_freqAxisCheckbox;
    NSButton      *_glassCheckbox;
    NSColorWell   *_barColorLightWell;
    NSColorWell   *_bgColorLightWell;
    NSColorWell   *_barColorDarkWell;
    NSColorWell   *_bgColorDarkWell;
    NSSlider      *_gridOpacitySlider;
    NSTextField   *_gridOpacityLabel;
    NSColorWell   *_gridColorLightWell;
    NSColorWell   *_gridColorDarkWell;
}
@end

@implementation SpectrumPreferences

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (NSString *)preferencesTitle { return @"Spectrum Analyzer"; }

- (void)loadView {
    SpectrumFlippedView *view = [[SpectrumFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 460, 870)];
    self.view = view;
    [NSColor setIgnoresAlpha:NO];
    [NSColorPanel sharedColorPanel].showsAlpha = YES;
    [self buildUI];
    [self loadSettings];
}

- (void)buildUI {
    CGFloat y = 10;
    const CGFloat labelX = 20;
    const CGFloat controlX = 150;

    NSTextField *title = JLCreatePreferencesTitle(@"Spectrum Analyzer");
    title.frame = NSMakeRect(labelX, y, 400, 20);
    [self.view addSubview:title];
    y += 30;

    // --- Analysis section ---
    NSTextField *analysisHeader = JLCreateSectionHeader(@"Analysis");
    analysisHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:analysisHeader];
    y += 22;

    [self.view addSubview:[self label:@"Bars:" at:NSMakePoint(labelX + 10, y + 3)]];
    _barCountPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 100, 25)];
    for (NSNumber *n in @[@16, @24, @32, @48, @64, @96, @128, @192, @256]) {
        [_barCountPopup addItemWithTitle:n.stringValue];
    }
    _barCountPopup.target = self; _barCountPopup.action = @selector(barCountChanged:);
    [self.view addSubview:_barCountPopup];
    y += 30;

    [self.view addSubview:[self label:@"FFT size:" at:NSMakePoint(labelX + 10, y + 3)]];
    _fftSizePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 100, 25)];
    for (NSNumber *n in @[@1024, @2048, @4096, @8192, @16384]) {
        [_fftSizePopup addItemWithTitle:n.stringValue];
    }
    _fftSizePopup.target = self; _fftSizePopup.action = @selector(fftSizeChanged:);
    [self.view addSubview:_fftSizePopup];
    y += 30;

    [self.view addSubview:[self label:@"Frequency scale:" at:NSMakePoint(labelX + 10, y + 3)]];
    _freqScalePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 130, 25)];
    [_freqScalePopup addItemWithTitle:@"Logarithmic"];
    [_freqScalePopup addItemWithTitle:@"Linear"];
    _freqScalePopup.target = self; _freqScalePopup.action = @selector(freqScaleChanged:);
    [self.view addSubview:_freqScalePopup];
    y += 30;

    [self.view addSubview:[self label:@"Range (Hz):" at:NSMakePoint(labelX + 10, y + 3)]];
    _minHzField = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX, y, 70, 22)];
    _minHzField.formatter = [self intFormatterMin:10 max:2000];
    _minHzField.target = self; _minHzField.action = @selector(rangeChanged:);
    [self.view addSubview:_minHzField];
    [self.view addSubview:[self label:@"to" at:NSMakePoint(controlX + 78, y + 3)]];
    _maxHzField = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX + 100, y, 70, 22)];
    _maxHzField.formatter = [self intFormatterMin:1000 max:24000];
    _maxHzField.target = self; _maxHzField.action = @selector(rangeChanged:);
    [self.view addSubview:_maxHzField];
    y += 30;

    [self.view addSubview:[self label:@"Smoothing:" at:NSMakePoint(labelX + 10, y + 3)]];
    _smoothingSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, 150, 22)];
    _smoothingSlider.minValue = 0; _smoothingSlider.maxValue = 100; _smoothingSlider.continuous = YES;
    _smoothingSlider.target = self; _smoothingSlider.action = @selector(smoothingChanged:);
    [self.view addSubview:_smoothingSlider];
    _smoothingLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_smoothingLabel];
    y += 34;

    // --- Dynamics section ---
    NSTextField *dynamicsHeader = JLCreateSectionHeader(@"Dynamics");
    dynamicsHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:dynamicsHeader];
    y += 22;

    [self.view addSubview:[self label:@"Shadow fall:" at:NSMakePoint(labelX + 10, y + 3)]];
    _shadowFallSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, 150, 22)];
    _shadowFallSlider.minValue = 0; _shadowFallSlider.maxValue = 100; _shadowFallSlider.continuous = YES;
    _shadowFallSlider.target = self; _shadowFallSlider.action = @selector(shadowFallChanged:);
    _shadowFallSlider.toolTip = @"How fast the shadow band falls (higher = faster)";
    [self.view addSubview:_shadowFallSlider];
    _shadowFallLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_shadowFallLabel];
    y += 30;

    [self.view addSubview:[self label:@"Peak fall:" at:NSMakePoint(labelX + 10, y + 3)]];
    _peakFallSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, 150, 22)];
    _peakFallSlider.minValue = 0; _peakFallSlider.maxValue = 100; _peakFallSlider.continuous = YES;
    _peakFallSlider.target = self; _peakFallSlider.action = @selector(peakFallChanged:);
    _peakFallSlider.toolTip = @"How fast the peak line falls after its hold (higher = faster)";
    [self.view addSubview:_peakFallSlider];
    _peakFallLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_peakFallLabel];
    y += 30;

    [self.view addSubview:[self label:@"Peak hold:" at:NSMakePoint(labelX + 10, y + 3)]];
    _peakHoldSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, 150, 22)];
    _peakHoldSlider.minValue = 0; _peakHoldSlider.maxValue = 2000; _peakHoldSlider.continuous = YES;
    _peakHoldSlider.target = self; _peakHoldSlider.action = @selector(peakHoldMsChanged:);
    _peakHoldSlider.toolTip = @"How long the peak line stays before it starts to fall";
    [self.view addSubview:_peakHoldSlider];
    _peakHoldLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_peakHoldLabel];
    y += 34;

    // --- Appearance section ---
    NSTextField *appearanceHeader = JLCreateSectionHeader(@"Appearance");
    appearanceHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:appearanceHeader];
    y += 22;

    [self.view addSubview:[self label:@"Theme:" at:NSMakePoint(labelX + 10, y + 3)]];
    _themePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 160, 25)];
    for (int i = 0; i < spectrum_config::kThemeCount; ++i) {
        [_themePopup addItemWithTitle:[NSString stringWithUTF8String:spectrum_config::kThemes[i].name]];
    }
    _themePopup.target = self; _themePopup.action = @selector(themeChanged:);
    _themePopup.toolTip = @"Apply a color preset to bars, background, and grid";
    [self.view addSubview:_themePopup];
    y += 30;

    [self.view addSubview:[self label:@"Draw mode:" at:NSMakePoint(labelX + 10, y + 3)]];
    _drawModePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 130, 25)];
    [_drawModePopup addItemWithTitle:@"Bars"];
    [_drawModePopup addItemWithTitle:@"Curve"];
    _drawModePopup.target = self; _drawModePopup.action = @selector(drawModeChanged:);
    [self.view addSubview:_drawModePopup];
    y += 30;

    [self.view addSubview:[self label:@"Orientation:" at:NSMakePoint(labelX + 10, y + 3)]];
    _orientationPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 130, 25)];
    [_orientationPopup addItemWithTitle:@"Horizontal"];
    [_orientationPopup addItemWithTitle:@"Vertical"];
    _orientationPopup.target = self; _orientationPopup.action = @selector(orientationChanged:);
    [self.view addSubview:_orientationPopup];
    y += 30;

    [self.view addSubview:[self label:@"Bar style:" at:NSMakePoint(labelX + 10, y + 3)]];
    _barStylePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 130, 25)];
    [_barStylePopup addItemWithTitle:@"Solid"];
    [_barStylePopup addItemWithTitle:@"Gradient"];
    [_barStylePopup addItemWithTitle:@"Spectrum"];
    _barStylePopup.target = self; _barStylePopup.action = @selector(barStyleChanged:);
    [self.view addSubview:_barStylePopup];
    y += 30;

    [self.view addSubview:[self label:@"Bar gap:" at:NSMakePoint(labelX + 10, y + 3)]];
    _gapSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, 150, 22)];
    _gapSlider.minValue = 0; _gapSlider.maxValue = 80; _gapSlider.continuous = YES;
    _gapSlider.target = self; _gapSlider.action = @selector(gapChanged:);
    [self.view addSubview:_gapSlider];
    _gapLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_gapLabel];
    y += 30;

    _peakHoldCheckbox = [self checkbox:@"Show peak caps" at:NSMakePoint(labelX + 10, y)];
    [self.view addSubview:_peakHoldCheckbox];
    y += 26;

    _shadowFillCheckbox = [self checkbox:@"Shadow fill" at:NSMakePoint(labelX + 10, y)];
    _shadowFillCheckbox.toolTip = @"Dim, slow-decaying fill behind bars for depth";
    [self.view addSubview:_shadowFillCheckbox];
    y += 26;

    _dbGuidesCheckbox = [self checkbox:@"Show dB scale" at:NSMakePoint(labelX + 10, y)];
    _dbGuidesCheckbox.toolTip = @"Draw decibel guide lines and labels on the right edge";
    [self.view addSubview:_dbGuidesCheckbox];
    y += 26;

    _freqAxisCheckbox = [self checkbox:@"Show frequency axis" at:NSMakePoint(labelX + 10, y)];
    _freqAxisCheckbox.toolTip = @"Draw frequency gridlines and labels along the bottom";
    [self.view addSubview:_freqAxisCheckbox];
    y += 26;

    _glassCheckbox = [self checkbox:@"Glass background" at:NSMakePoint(labelX + 10, y)];
    _glassCheckbox.toolTip = @"Translucent blur background instead of a solid color";
    [self.view addSubview:_glassCheckbox];
    y += 32;

    // Colors - light
    [self.view addSubview:[self label:@"Colors (Light Mode)" at:NSMakePoint(labelX, y)]];
    y += 22;
    [self.view addSubview:[self label:@"Bars:" at:NSMakePoint(labelX + 10, y + 3)]];
    _barColorLightWell = [self colorWellAt:NSMakePoint(controlX, y)];
    [self.view addSubview:_barColorLightWell];
    [self.view addSubview:[self label:@"Background:" at:NSMakePoint(controlX + 60, y + 3)]];
    _bgColorLightWell = [self colorWellAt:NSMakePoint(controlX + 150, y)];
    [self.view addSubview:_bgColorLightWell];
    y += 32;

    // Colors - dark
    [self.view addSubview:[self label:@"Colors (Dark Mode)" at:NSMakePoint(labelX, y)]];
    y += 22;
    [self.view addSubview:[self label:@"Bars:" at:NSMakePoint(labelX + 10, y + 3)]];
    _barColorDarkWell = [self colorWellAt:NSMakePoint(controlX, y)];
    [self.view addSubview:_barColorDarkWell];
    [self.view addSubview:[self label:@"Background:" at:NSMakePoint(controlX + 60, y + 3)]];
    _bgColorDarkWell = [self colorWellAt:NSMakePoint(controlX + 150, y)];
    [self.view addSubview:_bgColorDarkWell];
    y += 32;

    // --- Grid section (dB scale + frequency axis) ---
    NSTextField *gridHeader = JLCreateSectionHeader(@"Grid (dB scale & frequency axis)");
    gridHeader.frame = NSMakeRect(labelX, y, 300, 17);
    [self.view addSubview:gridHeader];
    y += 22;

    [self.view addSubview:[self label:@"Opacity:" at:NSMakePoint(labelX + 10, y + 3)]];
    _gridOpacitySlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, 150, 22)];
    _gridOpacitySlider.minValue = 0; _gridOpacitySlider.maxValue = 100; _gridOpacitySlider.continuous = YES;
    _gridOpacitySlider.target = self; _gridOpacitySlider.action = @selector(gridOpacityChanged:);
    [self.view addSubview:_gridOpacitySlider];
    _gridOpacityLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_gridOpacityLabel];
    y += 30;

    [self.view addSubview:[self label:@"Color (light):" at:NSMakePoint(labelX + 10, y + 3)]];
    _gridColorLightWell = [self colorWellAt:NSMakePoint(controlX, y)];
    [self.view addSubview:_gridColorLightWell];
    [self.view addSubview:[self label:@"Color (dark):" at:NSMakePoint(controlX + 60, y + 3)]];
    _gridColorDarkWell = [self colorWellAt:NSMakePoint(controlX + 150, y)];
    [self.view addSubview:_gridColorDarkWell];
    y += 32;
}

#pragma mark - Control factory helpers

- (NSTextField *)label:(NSString *)text at:(NSPoint)p {
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSMakeRect(p.x, p.y, 200, 17)];
    l.stringValue = text; l.editable = NO; l.bordered = NO;
    l.backgroundColor = [NSColor clearColor];
    l.font = [NSFont systemFontOfSize:11];
    return l;
}

- (NSTextField *)valueLabelAt:(NSPoint)p {
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSMakeRect(p.x, p.y, 50, 17)];
    l.editable = NO; l.bordered = NO;
    l.backgroundColor = [NSColor clearColor];
    l.font = [NSFont systemFontOfSize:11];
    return l;
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
    using namespace spectrum_config;

    [self selectPopup:_barCountPopup value:(int)getConfigInt(kKeyBarCount, kDefaultBarCount)];
    [self selectPopup:_fftSizePopup value:(int)getConfigInt(kKeyFftSize, kDefaultFftSize)];
    [_freqScalePopup selectItemAtIndex:getConfigInt(kKeyFreqScale, kDefaultFreqScale)];
    [_barStylePopup selectItemAtIndex:getConfigInt(kKeyBarStyle, kDefaultBarStyle)];
    [_drawModePopup selectItemAtIndex:getConfigInt(kKeyDrawMode, kDefaultDrawMode)];
    [_orientationPopup selectItemAtIndex:getConfigInt(kKeyOrientation, kDefaultOrientation)];

    _minHzField.integerValue = getConfigInt(kKeyMinHz, kDefaultMinHz);
    _maxHzField.integerValue = getConfigInt(kKeyMaxHz, kDefaultMaxHz);

    int smoothing = (int)getConfigInt(kKeySmoothing, kDefaultSmoothing);
    _smoothingSlider.integerValue = smoothing;
    _smoothingLabel.stringValue = [NSString stringWithFormat:@"%d%%", smoothing];

    int shadowFall = (int)getConfigInt(kKeyShadowFallSpeed, kDefaultShadowFallSpeed);
    _shadowFallSlider.integerValue = shadowFall;
    _shadowFallLabel.stringValue = [NSString stringWithFormat:@"%d%%", shadowFall];

    int peakFall = (int)getConfigInt(kKeyPeakFallSpeed, kDefaultPeakFallSpeed);
    _peakFallSlider.integerValue = peakFall;
    _peakFallLabel.stringValue = [NSString stringWithFormat:@"%d%%", peakFall];

    int peakHoldMs = (int)getConfigInt(kKeyPeakHoldMs, kDefaultPeakHoldMs);
    _peakHoldSlider.integerValue = peakHoldMs;
    _peakHoldLabel.stringValue = [NSString stringWithFormat:@"%dms", peakHoldMs];

    int gap = (int)getConfigInt(kKeyGapPercent, kDefaultGapPercent);
    _gapSlider.integerValue = gap;
    _gapLabel.stringValue = [NSString stringWithFormat:@"%d%%", gap];

    _peakHoldCheckbox.state = getConfigBool(kKeyPeakHold, kDefaultPeakHold) ? NSControlStateValueOn : NSControlStateValueOff;
    _shadowFillCheckbox.state = getConfigBool(kKeyShadowFill, kDefaultShadowFill) ? NSControlStateValueOn : NSControlStateValueOff;
    _dbGuidesCheckbox.state = getConfigBool(kKeyShowDbGuides, kDefaultShowDbGuides) ? NSControlStateValueOn : NSControlStateValueOff;
    _freqAxisCheckbox.state = getConfigBool(kKeyShowFreqAxis, kDefaultShowFreqAxis) ? NSControlStateValueOn : NSControlStateValueOff;
    _glassCheckbox.state = getConfigBool(kKeyGlassBackground, kDefaultGlassBackground) ? NSControlStateValueOn : NSControlStateValueOff;

    int gridOpacity = (int)getConfigInt(kKeyGridOpacity, kDefaultGridOpacity);
    _gridOpacitySlider.integerValue = gridOpacity;
    _gridOpacityLabel.stringValue = [NSString stringWithFormat:@"%d%%", gridOpacity];

    int theme = (int)getConfigInt(kKeyTheme, kDefaultTheme);
    if (theme < 0 || theme >= kThemeCount) theme = 0;
    [_themePopup selectItemAtIndex:theme];

    [self reloadColorWells];
}

- (void)reloadColorWells {
    using namespace spectrum_config;
    _barColorLightWell.color = [self colorFromARGB:(uint32_t)getConfigInt(kKeyBarColorLight, kDefaultBarColorLight)];
    _bgColorLightWell.color  = [self colorFromARGB:(uint32_t)getConfigInt(kKeyBgColorLight, kDefaultBgColorLight)];
    _barColorDarkWell.color  = [self colorFromARGB:(uint32_t)getConfigInt(kKeyBarColorDark, kDefaultBarColorDark)];
    _bgColorDarkWell.color   = [self colorFromARGB:(uint32_t)getConfigInt(kKeyBgColorDark, kDefaultBgColorDark)];
    _gridColorLightWell.color = [self colorFromARGB:(uint32_t)getConfigInt(kKeyGridColorLight, kDefaultGridColorLight)];
    _gridColorDarkWell.color  = [self colorFromARGB:(uint32_t)getConfigInt(kKeyGridColorDark, kDefaultGridColorDark)];
}

- (void)selectPopup:(NSPopUpButton *)popup value:(int)value {
    NSInteger idx = [popup indexOfItemWithTitle:[@(value) stringValue]];
    if (idx >= 0) [popup selectItemAtIndex:idx];
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
    [[NSNotificationCenter defaultCenter] postNotificationName:spectrum_config::kSettingsChangedNotification object:nil];
}

#pragma mark - Actions

- (void)barCountChanged:(id)sender {
    spectrum_config::setConfigInt(spectrum_config::kKeyBarCount, _barCountPopup.titleOfSelectedItem.intValue);
    [self notifyChanged];
}

- (void)fftSizeChanged:(id)sender {
    spectrum_config::setConfigInt(spectrum_config::kKeyFftSize, _fftSizePopup.titleOfSelectedItem.intValue);
    [self notifyChanged];
}

- (void)freqScaleChanged:(id)sender {
    spectrum_config::setConfigInt(spectrum_config::kKeyFreqScale, _freqScalePopup.indexOfSelectedItem);
    [self notifyChanged];
}

- (void)barStyleChanged:(id)sender {
    spectrum_config::setConfigInt(spectrum_config::kKeyBarStyle, _barStylePopup.indexOfSelectedItem);
    [self notifyChanged];
}

- (void)drawModeChanged:(id)sender {
    spectrum_config::setConfigInt(spectrum_config::kKeyDrawMode, _drawModePopup.indexOfSelectedItem);
    [self notifyChanged];
}

- (void)orientationChanged:(id)sender {
    spectrum_config::setConfigInt(spectrum_config::kKeyOrientation, _orientationPopup.indexOfSelectedItem);
    [self notifyChanged];
}

- (void)rangeChanged:(id)sender {
    using namespace spectrum_config;
    int lo = _minHzField.intValue;
    int hi = _maxHzField.intValue;
    if (hi <= lo + 100) { hi = lo + 100; _maxHzField.integerValue = hi; }
    setConfigInt(kKeyMinHz, lo);
    setConfigInt(kKeyMaxHz, hi);
    [self notifyChanged];
}

- (void)smoothingChanged:(id)sender {
    int v = (int)_smoothingSlider.integerValue;
    spectrum_config::setConfigInt(spectrum_config::kKeySmoothing, v);
    _smoothingLabel.stringValue = [NSString stringWithFormat:@"%d%%", v];
    [self notifyChanged];
}

- (void)shadowFallChanged:(id)sender {
    int v = (int)_shadowFallSlider.integerValue;
    spectrum_config::setConfigInt(spectrum_config::kKeyShadowFallSpeed, v);
    _shadowFallLabel.stringValue = [NSString stringWithFormat:@"%d%%", v];
    [self notifyChanged];
}

- (void)peakFallChanged:(id)sender {
    int v = (int)_peakFallSlider.integerValue;
    spectrum_config::setConfigInt(spectrum_config::kKeyPeakFallSpeed, v);
    _peakFallLabel.stringValue = [NSString stringWithFormat:@"%d%%", v];
    [self notifyChanged];
}

- (void)peakHoldMsChanged:(id)sender {
    int v = (int)_peakHoldSlider.integerValue;
    spectrum_config::setConfigInt(spectrum_config::kKeyPeakHoldMs, v);
    _peakHoldLabel.stringValue = [NSString stringWithFormat:@"%dms", v];
    [self notifyChanged];
}

- (void)gapChanged:(id)sender {
    int v = (int)_gapSlider.integerValue;
    spectrum_config::setConfigInt(spectrum_config::kKeyGapPercent, v);
    _gapLabel.stringValue = [NSString stringWithFormat:@"%d%%", v];
    [self notifyChanged];
}

- (void)checkboxChanged:(id)sender {
    using namespace spectrum_config;
    if (sender == _peakHoldCheckbox) {
        setConfigBool(kKeyPeakHold, _peakHoldCheckbox.state == NSControlStateValueOn);
    } else if (sender == _shadowFillCheckbox) {
        setConfigBool(kKeyShadowFill, _shadowFillCheckbox.state == NSControlStateValueOn);
    } else if (sender == _dbGuidesCheckbox) {
        setConfigBool(kKeyShowDbGuides, _dbGuidesCheckbox.state == NSControlStateValueOn);
    } else if (sender == _freqAxisCheckbox) {
        setConfigBool(kKeyShowFreqAxis, _freqAxisCheckbox.state == NSControlStateValueOn);
    } else if (sender == _glassCheckbox) {
        setConfigBool(kKeyGlassBackground, _glassCheckbox.state == NSControlStateValueOn);
    }
    [self notifyChanged];
}

- (void)themeChanged:(id)sender {
    using namespace spectrum_config;
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
    spectrum_config::setConfigInt(spectrum_config::kKeyGridOpacity, v);
    _gridOpacityLabel.stringValue = [NSString stringWithFormat:@"%d%%", v];
    [self notifyChanged];
}

- (void)colorChanged:(id)sender {
    using namespace spectrum_config;
    if (sender == _barColorLightWell)      setConfigInt(kKeyBarColorLight, [self argbFromColor:_barColorLightWell.color]);
    else if (sender == _bgColorLightWell)  setConfigInt(kKeyBgColorLight, [self argbFromColor:_bgColorLightWell.color]);
    else if (sender == _barColorDarkWell)  setConfigInt(kKeyBarColorDark, [self argbFromColor:_barColorDarkWell.color]);
    else if (sender == _bgColorDarkWell)   setConfigInt(kKeyBgColorDark, [self argbFromColor:_bgColorDarkWell.color]);
    else if (sender == _gridColorLightWell) setConfigInt(kKeyGridColorLight, [self argbFromColor:_gridColorLightWell.color]);
    else if (sender == _gridColorDarkWell)  setConfigInt(kKeyGridColorDark, [self argbFromColor:_gridColorDarkWell.color]);
    // A manual color edit means the palette no longer matches a preset.
    setConfigInt(kKeyTheme, 0);
    [_themePopup selectItemAtIndex:0];
    [self notifyChanged];
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
