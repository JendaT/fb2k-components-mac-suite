//
//  SpectrogramPreferences.mm
//  foo_jl_spectrogram_mac
//

#import "SpectrogramPreferences.h"
#include "../fb2k_sdk.h"
#include "../Core/SpectrogramConfig.h"
#include "../Core/SpectrogramColormaps.h"
#import "../../../../shared/PreferencesCommon.h"

// Uniquely-named flipped view (avoids ObjC runtime clashes across components)
@interface SpectrogramFlippedView : NSView
@end
@implementation SpectrogramFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface SpectrogramPreferences () {
    NSPopUpButton *_fftSizePopup;
    NSButton      *_multiResCheckbox;
    NSPopUpButton *_windowPopup;
    NSPopUpButton *_channelPopup;
    NSPopUpButton *_freqScalePopup;
    NSTextField   *_minHzField;
    NSTextField   *_maxHzField;
    NSPopUpButton *_colormapPopup;
    NSSlider      *_topDbSlider;
    NSTextField   *_topDbLabel;
    NSSlider      *_rangeDbSlider;
    NSTextField   *_rangeDbLabel;
    NSPopUpButton *_slopePopup;
    NSPopUpButton *_scrollSpeedPopup;
    NSButton      *_freqAxisCheckbox;
    NSButton      *_legendCheckbox;
    NSSlider      *_gridOpacitySlider;
    NSTextField   *_gridOpacityLabel;
}
@end

@implementation SpectrogramPreferences

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (NSString *)preferencesTitle { return @"Spectrogram"; }

- (void)loadView {
    SpectrogramFlippedView *view = [[SpectrogramFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 460, 520)];
    self.view = view;
    [self buildUI];
    [self loadSettings];
}

- (void)buildUI {
    CGFloat y = 10;
    const CGFloat labelX = 20;
    const CGFloat controlX = 150;

    NSTextField *title = JLCreatePreferencesTitle(@"Spectrogram");
    title.frame = NSMakeRect(labelX, y, 400, 20);
    [self.view addSubview:title];
    y += 30;

    // --- Analysis section ---
    NSTextField *analysisHeader = JLCreateSectionHeader(@"Analysis");
    analysisHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:analysisHeader];
    y += 22;

    [self.view addSubview:[self label:@"FFT size:" at:NSMakePoint(labelX + 10, y + 3)]];
    _fftSizePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 100, 25)];
    for (NSNumber *n in @[@1024, @2048, @4096, @8192, @16384]) {
        [_fftSizePopup addItemWithTitle:n.stringValue];
    }
    _fftSizePopup.toolTip = @"Window length at 44.1/48 kHz (scaled up at higher sample rates). Larger = finer pitch, blurrier timing";
    _fftSizePopup.target = self; _fftSizePopup.action = @selector(fftSizeChanged:);
    [self.view addSubview:_fftSizePopup];
    y += 30;

    _multiResCheckbox = [self checkbox:@"Multi-resolution" at:NSMakePoint(labelX + 10, y)];
    _multiResCheckbox.toolTip = @"Use a 4x longer window below ~300 Hz and a 4x shorter one above ~3 kHz";
    [self.view addSubview:_multiResCheckbox];
    y += 28;

    [self.view addSubview:[self label:@"Window:" at:NSMakePoint(labelX + 10, y + 3)]];
    _windowPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 150, 25)];
    [_windowPopup addItemWithTitle:@"Hann"];
    [_windowPopup addItemWithTitle:@"Blackman-Harris"];
    _windowPopup.toolTip = @"Blackman-Harris keeps loud tones from smearing over quiet detail at wide dB ranges, with slightly broader lines";
    _windowPopup.target = self; _windowPopup.action = @selector(popupChanged:);
    [self.view addSubview:_windowPopup];
    y += 30;

    [self.view addSubview:[self label:@"Channel:" at:NSMakePoint(labelX + 10, y + 3)]];
    _channelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 150, 25)];
    [_channelPopup addItemWithTitle:@"Mid (L + R)"];
    [_channelPopup addItemWithTitle:@"Left"];
    [_channelPopup addItemWithTitle:@"Right"];
    [_channelPopup addItemWithTitle:@"Side (L - R)"];
    _channelPopup.target = self; _channelPopup.action = @selector(popupChanged:);
    [self.view addSubview:_channelPopup];
    y += 30;

    [self.view addSubview:[self label:@"Frequency scale:" at:NSMakePoint(labelX + 10, y + 3)]];
    _freqScalePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 150, 25)];
    [_freqScalePopup addItemWithTitle:@"Logarithmic"];
    [_freqScalePopup addItemWithTitle:@"Mel"];
    [_freqScalePopup addItemWithTitle:@"Linear"];
    _freqScalePopup.target = self; _freqScalePopup.action = @selector(popupChanged:);
    [self.view addSubview:_freqScalePopup];
    y += 30;

    [self.view addSubview:[self label:@"Range (Hz):" at:NSMakePoint(labelX + 10, y + 3)]];
    _minHzField = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX, y, 70, 22)];
    _minHzField.formatter = [self intFormatterMin:10 max:2000];
    _minHzField.target = self; _minHzField.action = @selector(rangeChanged:);
    [self.view addSubview:_minHzField];
    [self.view addSubview:[self label:@"to" at:NSMakePoint(controlX + 78, y + 3)]];
    _maxHzField = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX + 100, y, 70, 22)];
    _maxHzField.formatter = [self intFormatterMin:1000 max:96000];
    _maxHzField.target = self; _maxHzField.action = @selector(rangeChanged:);
    [self.view addSubview:_maxHzField];
    y += 34;

    // --- Display section ---
    NSTextField *displayHeader = JLCreateSectionHeader(@"Display");
    displayHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:displayHeader];
    y += 22;

    [self.view addSubview:[self label:@"Colormap:" at:NSMakePoint(labelX + 10, y + 3)]];
    _colormapPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 150, 25)];
    for (int i = 0; i < spectrogram_colormap::kMapCount; ++i) {
        [_colormapPopup addItemWithTitle:[NSString stringWithUTF8String:spectrogram_colormap::kMaps[i].name]];
    }
    _colormapPopup.target = self; _colormapPopup.action = @selector(popupChanged:);
    [self.view addSubview:_colormapPopup];
    y += 30;

    [self.view addSubview:[self label:@"Top level:" at:NSMakePoint(labelX + 10, y + 3)]];
    _topDbSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, 150, 22)];
    _topDbSlider.minValue = -40; _topDbSlider.maxValue = 0; _topDbSlider.continuous = YES;
    _topDbSlider.target = self; _topDbSlider.action = @selector(topDbChanged:);
    _topDbSlider.toolTip = @"Level shown in the brightest color. Lower it for quiet material";
    [self.view addSubview:_topDbSlider];
    _topDbLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_topDbLabel];
    y += 30;

    [self.view addSubview:[self label:@"Range:" at:NSMakePoint(labelX + 10, y + 3)]];
    _rangeDbSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, 150, 22)];
    _rangeDbSlider.minValue = 40; _rangeDbSlider.maxValue = 140; _rangeDbSlider.continuous = YES;
    _rangeDbSlider.target = self; _rangeDbSlider.action = @selector(rangeDbChanged:);
    _rangeDbSlider.toolTip = @"dB span below the top level. Smaller = more contrast, less quiet detail";
    [self.view addSubview:_rangeDbSlider];
    _rangeDbLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_rangeDbLabel];
    y += 30;

    [self.view addSubview:[self label:@"Slope:" at:NSMakePoint(labelX + 10, y + 3)]];
    _slopePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 150, 25)];
    // Item tags hold the stored value: tenths of dB per octave.
    for (NSNumber *n in @[@0, @15, @30, @45, @60]) {
        NSString *t = n.intValue == 0 ? @"Off" : [NSString stringWithFormat:@"%g dB/octave", n.intValue / 10.0];
        [_slopePopup addItemWithTitle:t];
        _slopePopup.lastItem.tag = n.integerValue;
    }
    _slopePopup.toolTip = @"Tilt around 1 kHz that brightens treble and dims bass. The dB scale is exact only at 1 kHz when on";
    _slopePopup.target = self; _slopePopup.action = @selector(popupChanged:);
    [self.view addSubview:_slopePopup];
    y += 30;

    [self.view addSubview:[self label:@"Scroll speed:" at:NSMakePoint(labelX + 10, y + 3)]];
    _scrollSpeedPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 150, 25)];
    // Item tags hold the stored value: points per second.
    for (NSNumber *n in @[@30, @60, @120, @240]) {
        [_scrollSpeedPopup addItemWithTitle:[NSString stringWithFormat:@"%@ pt/s", n]];
        _scrollSpeedPopup.lastItem.tag = n.integerValue;
    }
    _scrollSpeedPopup.target = self; _scrollSpeedPopup.action = @selector(popupChanged:);
    [self.view addSubview:_scrollSpeedPopup];
    y += 32;

    _freqAxisCheckbox = [self checkbox:@"Show frequency axis" at:NSMakePoint(labelX + 10, y)];
    [self.view addSubview:_freqAxisCheckbox];
    y += 26;

    _legendCheckbox = [self checkbox:@"Show dB color scale" at:NSMakePoint(labelX + 10, y)];
    [self.view addSubview:_legendCheckbox];
    y += 28;

    [self.view addSubview:[self label:@"Grid lines:" at:NSMakePoint(labelX + 10, y + 3)]];
    _gridOpacitySlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, 150, 22)];
    _gridOpacitySlider.minValue = 0; _gridOpacitySlider.maxValue = 100; _gridOpacitySlider.continuous = YES;
    _gridOpacitySlider.target = self; _gridOpacitySlider.action = @selector(gridOpacityChanged:);
    _gridOpacitySlider.toolTip = @"Opacity of the lines across the plot at labelled frequencies (0% hides them)";
    [self.view addSubview:_gridOpacitySlider];
    _gridOpacityLabel = [self valueLabelAt:NSMakePoint(controlX + 160, y + 2)];
    [self.view addSubview:_gridOpacityLabel];
    y += 30;
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
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSMakeRect(p.x, p.y, 60, 17)];
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

- (NSNumberFormatter *)intFormatterMin:(int)lo max:(int)hi {
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    f.numberStyle = NSNumberFormatterNoStyle;
    f.minimum = @(lo); f.maximum = @(hi);
    f.allowsFloats = NO;
    return f;
}

#pragma mark - Load / persist

- (void)loadSettings {
    using namespace spectrogram_config;

    [self selectPopup:_fftSizePopup value:(int)getConfigInt(kKeyFftSize, kDefaultFftSize)];
    [self selectIndexPopup:_windowPopup index:getConfigInt(kKeyWindow, kDefaultWindow)];
    [self selectIndexPopup:_channelPopup index:getConfigInt(kKeyChannel, kDefaultChannel)];
    [self selectIndexPopup:_freqScalePopup index:getConfigInt(kKeyFreqScale, kDefaultFreqScale)];
    [self selectIndexPopup:_colormapPopup index:getConfigInt(kKeyColormap, kDefaultColormap)];
    if (![_slopePopup selectItemWithTag:getConfigInt(kKeySlopeTenths, kDefaultSlopeTenths)])
        [_slopePopup selectItemWithTag:kDefaultSlopeTenths];
    if (![_scrollSpeedPopup selectItemWithTag:getConfigInt(kKeyScrollSpeed, kDefaultScrollSpeed)])
        [_scrollSpeedPopup selectItemWithTag:kDefaultScrollSpeed];

    _minHzField.integerValue = getConfigInt(kKeyMinHz, kDefaultMinHz);
    _maxHzField.integerValue = getConfigInt(kKeyMaxHz, kDefaultMaxHz);

    int topDb = (int)getConfigInt(kKeyTopDb, kDefaultTopDb);
    _topDbSlider.integerValue = topDb;
    _topDbLabel.stringValue = [NSString stringWithFormat:@"%d dB", topDb];

    int rangeDb = (int)getConfigInt(kKeyRangeDb, kDefaultRangeDb);
    _rangeDbSlider.integerValue = rangeDb;
    _rangeDbLabel.stringValue = [NSString stringWithFormat:@"%d dB", rangeDb];

    int gridOpacity = (int)getConfigInt(kKeyGridOpacity, kDefaultGridOpacity);
    _gridOpacitySlider.integerValue = gridOpacity;
    _gridOpacityLabel.stringValue = [NSString stringWithFormat:@"%d%%", gridOpacity];

    _multiResCheckbox.state = getConfigBool(kKeyMultiRes, kDefaultMultiRes) ? NSControlStateValueOn : NSControlStateValueOff;
    _freqAxisCheckbox.state = getConfigBool(kKeyShowFreqAxis, kDefaultShowFreqAxis) ? NSControlStateValueOn : NSControlStateValueOff;
    _legendCheckbox.state = getConfigBool(kKeyShowLegend, kDefaultShowLegend) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)selectPopup:(NSPopUpButton *)popup value:(int)value {
    NSInteger idx = [popup indexOfItemWithTitle:[@(value) stringValue]];
    if (idx >= 0) [popup selectItemAtIndex:idx];
}

// Config values index these popups directly; an out-of-range value from a
// corrupted config store would raise NSRangeException, so clamp first.
- (void)selectIndexPopup:(NSPopUpButton *)popup index:(NSInteger)idx {
    if (idx < 0 || idx >= popup.numberOfItems) idx = 0;
    [popup selectItemAtIndex:idx];
}

- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:spectrogram_config::kSettingsChangedNotification object:nil];
}

#pragma mark - Actions

- (void)fftSizeChanged:(id)sender {
    spectrogram_config::setConfigInt(spectrogram_config::kKeyFftSize, _fftSizePopup.titleOfSelectedItem.intValue);
    [self notifyChanged];
}

- (void)popupChanged:(id)sender {
    using namespace spectrogram_config;
    if (sender == _windowPopup)           setConfigInt(kKeyWindow, _windowPopup.indexOfSelectedItem);
    else if (sender == _channelPopup)     setConfigInt(kKeyChannel, _channelPopup.indexOfSelectedItem);
    else if (sender == _freqScalePopup)   setConfigInt(kKeyFreqScale, _freqScalePopup.indexOfSelectedItem);
    else if (sender == _colormapPopup)    setConfigInt(kKeyColormap, _colormapPopup.indexOfSelectedItem);
    else if (sender == _slopePopup)       setConfigInt(kKeySlopeTenths, _slopePopup.selectedItem.tag);
    else if (sender == _scrollSpeedPopup) setConfigInt(kKeyScrollSpeed, _scrollSpeedPopup.selectedItem.tag);
    [self notifyChanged];
}

- (void)rangeChanged:(id)sender {
    using namespace spectrogram_config;
    int lo = _minHzField.intValue;
    int hi = _maxHzField.intValue;
    if (hi <= lo + 100) { hi = lo + 100; _maxHzField.integerValue = hi; }
    setConfigInt(kKeyMinHz, lo);
    setConfigInt(kKeyMaxHz, hi);
    [self notifyChanged];
}

- (void)topDbChanged:(id)sender {
    int v = (int)_topDbSlider.integerValue;
    spectrogram_config::setConfigInt(spectrogram_config::kKeyTopDb, v);
    _topDbLabel.stringValue = [NSString stringWithFormat:@"%d dB", v];
    [self notifyChanged];
}

- (void)rangeDbChanged:(id)sender {
    int v = (int)_rangeDbSlider.integerValue;
    spectrogram_config::setConfigInt(spectrogram_config::kKeyRangeDb, v);
    _rangeDbLabel.stringValue = [NSString stringWithFormat:@"%d dB", v];
    [self notifyChanged];
}

- (void)gridOpacityChanged:(id)sender {
    int v = (int)_gridOpacitySlider.integerValue;
    spectrogram_config::setConfigInt(spectrogram_config::kKeyGridOpacity, v);
    _gridOpacityLabel.stringValue = [NSString stringWithFormat:@"%d%%", v];
    [self notifyChanged];
}

- (void)checkboxChanged:(id)sender {
    using namespace spectrogram_config;
    if (sender == _multiResCheckbox) {
        setConfigBool(kKeyMultiRes, _multiResCheckbox.state == NSControlStateValueOn);
    } else if (sender == _freqAxisCheckbox) {
        setConfigBool(kKeyShowFreqAxis, _freqAxisCheckbox.state == NSControlStateValueOn);
    } else if (sender == _legendCheckbox) {
        setConfigBool(kKeyShowLegend, _legendCheckbox.state == NSControlStateValueOn);
    }
    [self notifyChanged];
}

@end

// --- Preferences page registration ---
namespace {
    class spectrogram_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            return fb2k::wrapNSObject([[SpectrogramPreferences alloc] init]);
        }
        const char* get_name() override { return "Spectrogram"; }
        GUID get_guid() override { return spectrogram_config::guid_preferences_page; }
        GUID get_parent_guid() override { return preferences_page::guid_display; }
    };
    FB2K_SERVICE_FACTORY(spectrogram_preferences_page);
}
