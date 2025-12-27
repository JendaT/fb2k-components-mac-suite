//
//  WaveformPreferences.mm
//  foo_wave_seekbar_mac
//
//  Preferences page for waveform seekbar configuration
//

#import "WaveformPreferences.h"
#include "../fb2k_sdk.h"
#include "../Core/WaveformConfig.h"
#include "../Core/ConfigHelper.h"
#include "../Core/WaveformCache.h"
#import "../../../../shared/PreferencesCommon.h"

// Flipped view for top-to-bottom layout (unique class name per extension)
@interface WaveformFlippedView : NSView
@end
@implementation WaveformFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface WaveformPreferences () {
    // Display settings
    NSPopUpButton *_displayModePopup;
    NSPopUpButton *_waveformStylePopup;
    NSPopUpButton *_gradientBandsPopup;
    NSButton *_shadePlayedCheckbox;

    // Light mode colors
    NSColorWell *_waveColorLightWell;
    NSColorWell *_bgColorLightWell;

    // Dark mode colors
    NSColorWell *_waveColorDarkWell;
    NSColorWell *_bgColorDarkWell;

    // Played dimming
    NSSlider *_playedOpacitySlider;
    NSTextField *_playedOpacityLabel;

    // Cursor effect
    NSPopUpButton *_cursorEffectPopup;
    NSButton *_bpmSyncCheckbox;

    // Cache settings
    NSTextField *_cacheSizeField;
    NSTextField *_retentionField;
    NSTextField *_cacheStatusLabel;
    NSButton *_clearCacheButton;
}

@end

@implementation WaveformPreferences

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    return self;
}

- (NSString *)preferencesTitle {
    return @"Waveform Seekbar";
}

- (void)loadView {
    WaveformFlippedView *view = [[WaveformFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 450, 420)];
    self.view = view;

    [self buildUI];
    [self loadSettings];
}

- (void)buildUI {
    CGFloat y = 10;  // Start from top (flipped coordinate system)
    CGFloat labelX = 20;
    CGFloat controlX = 130;

    // Page title (non-bold, matches foobar2000 style)
    NSTextField *title = JLCreatePreferencesTitle(@"Waveform Seekbar");
    title.frame = NSMakeRect(labelX, y, 400, 20);
    [self.view addSubview:title];
    y += 28;

    // Display section header
    NSTextField *displayHeader = JLCreateSectionHeader(@"Display");
    displayHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:displayHeader];
    y += 22;

    // Display Mode
    [self.view addSubview:[self createLabel:@"Display Mode:" at:NSMakePoint(labelX + 10, y + 3)]];
    _displayModePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 150, 25)];
    [_displayModePopup addItemWithTitle:@"Stereo (L/R)"];
    [_displayModePopup addItemWithTitle:@"Mono"];
    [_displayModePopup setTarget:self];
    [_displayModePopup setAction:@selector(displayModeChanged:)];
    [self.view addSubview:_displayModePopup];
    y += 30;

    // Waveform Style
    [self.view addSubview:[self createLabel:@"Waveform style:" at:NSMakePoint(labelX + 10, y + 3)]];
    _waveformStylePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 150, 25)];
    [_waveformStylePopup addItemWithTitle:@"Solid"];
    [_waveformStylePopup addItemWithTitle:@"Heat map"];
    [_waveformStylePopup addItemWithTitle:@"Rainbow"];
    [_waveformStylePopup setTarget:self];
    [_waveformStylePopup setAction:@selector(waveformStyleChanged:)];
    [self.view addSubview:_waveformStylePopup];
    y += 30;

    // Gradient Bands (only applies to Solid style)
    [self.view addSubview:[self createLabel:@"Gradient bands:" at:NSMakePoint(labelX + 10, y + 3)]];
    _gradientBandsPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 80, 25)];
    // Add options: 0 (none), 2, 4, 8, 12, 16, 24, 32
    [_gradientBandsPopup addItemWithTitle:@"0"];
    [_gradientBandsPopup addItemWithTitle:@"2"];
    [_gradientBandsPopup addItemWithTitle:@"4"];
    [_gradientBandsPopup addItemWithTitle:@"8"];
    [_gradientBandsPopup addItemWithTitle:@"12"];
    [_gradientBandsPopup addItemWithTitle:@"16"];
    [_gradientBandsPopup addItemWithTitle:@"24"];
    [_gradientBandsPopup addItemWithTitle:@"32"];
    [_gradientBandsPopup setTarget:self];
    [_gradientBandsPopup setAction:@selector(gradientBandsChanged:)];
    [self.view addSubview:_gradientBandsPopup];
    y += 30;

    // Shade played portion
    _shadePlayedCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 250, 20)];
    _shadePlayedCheckbox.buttonType = NSButtonTypeSwitch;
    _shadePlayedCheckbox.title = @"Shade played portion";
    [_shadePlayedCheckbox setTarget:self];
    [_shadePlayedCheckbox setAction:@selector(checkboxChanged:)];
    [self.view addSubview:_shadePlayedCheckbox];
    y += 32;

    // Colors section - Light Mode
    [self.view addSubview:[self createLabel:@"Colors (Light Mode)" at:NSMakePoint(labelX, y)]];
    y += 22;

    [self.view addSubview:[self createLabel:@"Waveform:" at:NSMakePoint(labelX + 10, y + 3)]];
    _waveColorLightWell = [self createColorWellAt:NSMakePoint(controlX, y)];
    [self.view addSubview:_waveColorLightWell];

    [self.view addSubview:[self createLabel:@"Background:" at:NSMakePoint(200, y + 3)]];
    _bgColorLightWell = [self createColorWellAt:NSMakePoint(280, y)];
    [self.view addSubview:_bgColorLightWell];
    y += 32;

    // Colors section - Dark Mode
    [self.view addSubview:[self createLabel:@"Colors (Dark Mode)" at:NSMakePoint(labelX, y)]];
    y += 22;

    [self.view addSubview:[self createLabel:@"Waveform:" at:NSMakePoint(labelX + 10, y + 3)]];
    _waveColorDarkWell = [self createColorWellAt:NSMakePoint(controlX, y)];
    [self.view addSubview:_waveColorDarkWell];

    [self.view addSubview:[self createLabel:@"Background:" at:NSMakePoint(200, y + 3)]];
    _bgColorDarkWell = [self createColorWellAt:NSMakePoint(280, y)];
    [self.view addSubview:_bgColorDarkWell];
    y += 32;

    // Played portion opacity
    [self.view addSubview:[self createLabel:@"Played dimming:" at:NSMakePoint(labelX + 10, y + 3)]];
    _playedOpacitySlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, 150, 22)];
    _playedOpacitySlider.minValue = 0;
    _playedOpacitySlider.maxValue = 100;
    _playedOpacitySlider.continuous = YES;
    [_playedOpacitySlider setTarget:self];
    [_playedOpacitySlider setAction:@selector(opacityChanged:)];
    [self.view addSubview:_playedOpacitySlider];

    _playedOpacityLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX + 160, y + 2, 40, 17)];
    _playedOpacityLabel.editable = NO;
    _playedOpacityLabel.bordered = NO;
    _playedOpacityLabel.backgroundColor = [NSColor clearColor];
    _playedOpacityLabel.font = [NSFont systemFontOfSize:11];
    [self.view addSubview:_playedOpacityLabel];
    y += 30;

    // Cursor effect
    [self.view addSubview:[self createLabel:@"Cursor effect:" at:NSMakePoint(labelX + 10, y + 3)]];
    _cursorEffectPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 140, 25) pullsDown:NO];
    [_cursorEffectPopup addItemWithTitle:@"None"];
    [_cursorEffectPopup addItemWithTitle:@"Gradient"];
    [_cursorEffectPopup addItemWithTitle:@"Glow"];
    [_cursorEffectPopup addItemWithTitle:@"Scanline"];
    [_cursorEffectPopup addItemWithTitle:@"Pulse"];
    [_cursorEffectPopup addItemWithTitle:@"Trail"];
    [_cursorEffectPopup addItemWithTitle:@"Shimmer"];
    [_cursorEffectPopup setTarget:self];
    [_cursorEffectPopup setAction:@selector(cursorEffectChanged:)];
    [self.view addSubview:_cursorEffectPopup];
    y += 30;

    // BPM sync checkbox
    _bpmSyncCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 250, 20)];
    _bpmSyncCheckbox.buttonType = NSButtonTypeSwitch;
    _bpmSyncCheckbox.title = @"Sync animations to track BPM";
    [_bpmSyncCheckbox setTarget:self];
    [_bpmSyncCheckbox setAction:@selector(bpmSyncChanged:)];
    [self.view addSubview:_bpmSyncCheckbox];
    y += 32;

    // Cache section
    [self.view addSubview:[self createLabel:@"Cache" at:NSMakePoint(labelX, y)]];
    y += 22;

    [self.view addSubview:[self createLabel:@"Max size:" at:NSMakePoint(labelX + 10, y + 3)]];
    _cacheSizeField = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX, y, 70, 22)];
    _cacheSizeField.formatter = [[NSNumberFormatter alloc] init];
    ((NSNumberFormatter *)_cacheSizeField.formatter).minimum = @1;
    ((NSNumberFormatter *)_cacheSizeField.formatter).maximum = @10000;
    [_cacheSizeField setTarget:self];
    [_cacheSizeField setAction:@selector(cacheSettingChanged:)];
    [self.view addSubview:_cacheSizeField];
    [self.view addSubview:[self createLabel:@"MB" at:NSMakePoint(205, y + 3)]];

    [self.view addSubview:[self createLabel:@"Keep for:" at:NSMakePoint(250, y + 3)]];
    _retentionField = [[NSTextField alloc] initWithFrame:NSMakeRect(320, y, 60, 22)];
    _retentionField.formatter = [[NSNumberFormatter alloc] init];
    ((NSNumberFormatter *)_retentionField.formatter).minimum = @1;
    ((NSNumberFormatter *)_retentionField.formatter).maximum = @3650;
    [_retentionField setTarget:self];
    [_retentionField setAction:@selector(cacheSettingChanged:)];
    [self.view addSubview:_retentionField];
    [self.view addSubview:[self createLabel:@"days" at:NSMakePoint(385, y + 3)]];
    y += 28;

    // Cache status and clear button
    _cacheStatusLabel = [self createLabel:@"Cache: Loading..." at:NSMakePoint(labelX + 10, y + 3)];
    _cacheStatusLabel.textColor = [NSColor secondaryLabelColor];
    [self.view addSubview:_cacheStatusLabel];

    _clearCacheButton = [[NSButton alloc] initWithFrame:NSMakeRect(320, y, 100, 25)];
    _clearCacheButton.bezelStyle = NSBezelStyleRounded;
    _clearCacheButton.title = @"Clear Cache";
    [_clearCacheButton setTarget:self];
    [_clearCacheButton setAction:@selector(clearCacheClicked:)];
    [self.view addSubview:_clearCacheButton];

    [self updateCacheStatus];
}

- (NSTextField *)createLabel:(NSString *)text at:(NSPoint)point {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(point.x, point.y, 200, 17)];
    label.stringValue = text;
    label.editable = NO;
    label.bordered = NO;
    label.backgroundColor = [NSColor clearColor];
    label.font = [NSFont systemFontOfSize:11];
    return label;
}

- (NSColorWell *)createColorWellAt:(NSPoint)point {
    NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(point.x, point.y, 40, 24)];
    [well setTarget:self];
    [well setAction:@selector(colorChanged:)];

    // Use popover-style color picker on macOS 13+ (Ventura) for better positioning
    if (@available(macOS 13.0, *)) {
        well.colorWellStyle = NSColorWellStyleMinimal;
    }

    return well;
}

- (void)loadSettings {
    using namespace waveform_config;

    // Display mode
    [_displayModePopup selectItemAtIndex:getConfigInt(kKeyDisplayMode, kDefaultDisplayMode)];

    // Waveform style
    [_waveformStylePopup selectItemAtIndex:getConfigInt(kKeyWaveformStyle, kDefaultWaveformStyle)];

    // Gradient bands - map value to popup index
    int64_t bands = getConfigInt(kKeyGradientBands, kDefaultGradientBands);
    NSInteger bandsIndex = 3;  // Default to 8 (index 3)
    if (bands == 0) bandsIndex = 0;
    else if (bands == 2) bandsIndex = 1;
    else if (bands == 4) bandsIndex = 2;
    else if (bands == 8) bandsIndex = 3;
    else if (bands == 12) bandsIndex = 4;
    else if (bands == 16) bandsIndex = 5;
    else if (bands == 24) bandsIndex = 6;
    else if (bands == 32) bandsIndex = 7;
    [_gradientBandsPopup selectItemAtIndex:bandsIndex];

    // Checkboxes
    _shadePlayedCheckbox.state = getConfigBool(kKeyShadePlayedPortion, kDefaultShadePlayedPortion) ? NSControlStateValueOn : NSControlStateValueOff;

    // Light mode colors
    _waveColorLightWell.color = [self colorFromARGB:static_cast<uint32_t>(getConfigInt(kKeyWaveColorLight, kDefaultWaveColorLight))];
    _bgColorLightWell.color = [self colorFromARGB:static_cast<uint32_t>(getConfigInt(kKeyBgColorLight, kDefaultBgColorLight))];

    // Dark mode colors
    _waveColorDarkWell.color = [self colorFromARGB:static_cast<uint32_t>(getConfigInt(kKeyWaveColorDark, kDefaultWaveColorDark))];
    _bgColorDarkWell.color = [self colorFromARGB:static_cast<uint32_t>(getConfigInt(kKeyBgColorDark, kDefaultBgColorDark))];

    // Played dimming opacity (0-100)
    int64_t opacity = getConfigInt(kKeyPlayedDimming, kDefaultPlayedDimming);
    _playedOpacitySlider.integerValue = opacity;
    _playedOpacityLabel.stringValue = [NSString stringWithFormat:@"%lld%%", opacity];

    // Cursor effect
    [_cursorEffectPopup selectItemAtIndex:getConfigInt(kKeyCursorEffect, kDefaultCursorEffect)];

    // BPM sync
    _bpmSyncCheckbox.state = getConfigBool(kKeyBpmSync, kDefaultBpmSync) ? NSControlStateValueOn : NSControlStateValueOff;

    // Cache settings
    _cacheSizeField.integerValue = getConfigInt(kKeyCacheSizeMB, kDefaultCacheSizeMB);
    _retentionField.integerValue = getConfigInt(kKeyCacheRetentionDays, kDefaultCacheRetentionDays);
}

- (NSColor *)colorFromARGB:(uint32_t)argb {
    return [NSColor colorWithRed:((argb >> 16) & 0xFF) / 255.0
                           green:((argb >> 8) & 0xFF) / 255.0
                            blue:(argb & 0xFF) / 255.0
                           alpha:((argb >> 24) & 0xFF) / 255.0];
}

- (uint32_t)argbFromColor:(NSColor *)color {
    NSColor *rgbColor = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!rgbColor) return 0xFF000000;

    uint32_t a = static_cast<uint32_t>(rgbColor.alphaComponent * 255) & 0xFF;
    uint32_t r = static_cast<uint32_t>(rgbColor.redComponent * 255) & 0xFF;
    uint32_t g = static_cast<uint32_t>(rgbColor.greenComponent * 255) & 0xFF;
    uint32_t b = static_cast<uint32_t>(rgbColor.blueComponent * 255) & 0xFF;

    return (a << 24) | (r << 16) | (g << 8) | b;
}

- (void)updateCacheStatus {
    WaveformCache::CacheStats stats = getWaveformCache().getStats();

    NSString *sizeStr;
    if (stats.totalSizeBytes < 1024 * 1024) {
        sizeStr = [NSString stringWithFormat:@"%.0f KB", stats.totalSizeBytes / 1024.0];
    } else {
        sizeStr = [NSString stringWithFormat:@"%.1f MB", stats.totalSizeBytes / (1024.0 * 1024.0)];
    }

    _cacheStatusLabel.stringValue = [NSString stringWithFormat:@"Cache: %@, %lu tracks",
                                     sizeStr, (unsigned long)stats.entryCount];
}

#pragma mark - Actions

- (void)notifySettingsChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"WaveformSeekbarSettingsChanged"
                                                        object:nil];
}

- (void)displayModeChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeyDisplayMode, [_displayModePopup indexOfSelectedItem]);
    [self notifySettingsChanged];
}

- (void)waveformStyleChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeyWaveformStyle, [_waveformStylePopup indexOfSelectedItem]);
    [self notifySettingsChanged];
}

- (void)gradientBandsChanged:(id)sender {
    using namespace waveform_config;
    // Map popup index to actual value
    int values[] = {0, 2, 4, 8, 12, 16, 24, 32};
    NSInteger index = [_gradientBandsPopup indexOfSelectedItem];
    if (index >= 0 && index < 8) {
        setConfigInt(kKeyGradientBands, values[index]);
        [self notifySettingsChanged];
    }
}

- (void)checkboxChanged:(id)sender {
    using namespace waveform_config;
    if (sender == _shadePlayedCheckbox) {
        setConfigBool(kKeyShadePlayedPortion, _shadePlayedCheckbox.state == NSControlStateValueOn);
    }
    [self notifySettingsChanged];
}

- (void)colorChanged:(id)sender {
    using namespace waveform_config;
    if (sender == _waveColorLightWell) {
        setConfigInt(kKeyWaveColorLight, [self argbFromColor:_waveColorLightWell.color]);
    } else if (sender == _bgColorLightWell) {
        setConfigInt(kKeyBgColorLight, [self argbFromColor:_bgColorLightWell.color]);
    } else if (sender == _waveColorDarkWell) {
        setConfigInt(kKeyWaveColorDark, [self argbFromColor:_waveColorDarkWell.color]);
    } else if (sender == _bgColorDarkWell) {
        setConfigInt(kKeyBgColorDark, [self argbFromColor:_bgColorDarkWell.color]);
    }
    [self notifySettingsChanged];
}

- (void)opacityChanged:(id)sender {
    using namespace waveform_config;
    NSInteger value = _playedOpacitySlider.integerValue;
    setConfigInt(kKeyPlayedDimming, value);
    _playedOpacityLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)value];
    [self notifySettingsChanged];
}

- (void)cursorEffectChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeyCursorEffect, [_cursorEffectPopup indexOfSelectedItem]);
    [self notifySettingsChanged];
}

- (void)bpmSyncChanged:(id)sender {
    using namespace waveform_config;
    setConfigBool(kKeyBpmSync, _bpmSyncCheckbox.state == NSControlStateValueOn);
    [self notifySettingsChanged];
}

- (void)cacheSettingChanged:(id)sender {
    using namespace waveform_config;
    if (sender == _cacheSizeField) {
        setConfigInt(kKeyCacheSizeMB, _cacheSizeField.integerValue);
    } else if (sender == _retentionField) {
        setConfigInt(kKeyCacheRetentionDays, _retentionField.integerValue);
    }
}

- (void)clearCacheClicked:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Clear Waveform Cache";
    alert.informativeText = @"Are you sure you want to clear all cached waveforms? They will be regenerated as needed.";
    [alert addButtonWithTitle:@"Clear"];
    [alert addButtonWithTitle:@"Cancel"];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        getWaveformCache().clearCache();
        [self updateCacheStatus];
    }
}

@end

// Preferences page registration
namespace {
    static const GUID guid_preferences_page = {
        0xABCD1234, 0x5678, 0x9ABC,
        {0xDE, 0xF0, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC}
    };

    class waveform_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            return fb2k::wrapNSObject([[WaveformPreferences alloc] init]);
        }

        const char* get_name() override {
            return "Waveform Seekbar";
        }

        GUID get_guid() override {
            return guid_preferences_page;
        }

        GUID get_parent_guid() override {
            return preferences_page::guid_display;
        }
    };

    FB2K_SERVICE_FACTORY(waveform_preferences_page);
}
