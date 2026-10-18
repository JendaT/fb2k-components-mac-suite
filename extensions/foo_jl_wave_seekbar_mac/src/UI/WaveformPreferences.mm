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
#include "../Core/WaveformThemes.h"
#include "../Core/WaveformService.h"
#include "../Core/WaveformColorMap.h"
#include "../Core/GradientBandTable.h"
#import "../../../../shared/PreferencesCommon.h"
#include "../Integration/ComponentInfo.h"
#include <algorithm>

// Flipped view for top-to-bottom layout (unique class name per extension)
@interface WaveformFlippedView : NSView
@end
@implementation WaveformFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface WaveformPreferences () {
    // Display settings
    NSPopUpButton *_stylePopup;
    NSTextField *_styleHint;
    NSPopUpButton *_channelsPopup;
    NSButton *_glassBackgroundCheckbox;

    // Color preset
    NSPopUpButton *_themePopup;

    // Light mode colors
    NSColorWell *_waveColorLightWell;
    NSColorWell *_bgColorLightWell;

    // Dark mode colors
    NSColorWell *_waveColorDarkWell;
    NSColorWell *_bgColorDarkWell;

    // Played part and cursor
    NSSlider *_playedOpacitySlider;
    NSTextField *_playedOpacityLabel;
    NSButton *_cursorTimeCheckbox;

    // Overlays
    NSButton *_readoutCheckbox;
    NSPopUpButton *_summaryPopup;
    NSButton *_clipMarkersCheckbox;

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
    WaveformFlippedView *view = [[WaveformFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 450, 655)];
    self.view = view;

    // Allow transparent colors (alpha slider in the color panel)
    [NSColor setIgnoresAlpha:NO];
    [NSColorPanel sharedColorPanel].showsAlpha = YES;

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
    JLAddPreferencesInfoButton(self.view, title, self, @selector(showComponentInfo:));
    y += 28;

    // Display section header
    NSTextField *displayHeader = JLCreateSectionHeader(@"Display");
    displayHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:displayHeader];
    y += 22;

    // Style, with a one-line description under it
    [self.view addSubview:[self createLabel:@"Style:" at:NSMakePoint(labelX + 10, y + 3)]];
    _stylePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 250, 25)];
    for (NSString *title in @[ @"Layered — peak + loudness (dBFS)", @"Simple — Two-tone",
                               @"Simple — Glow", @"Simple — Heat" ]) {
        [_stylePopup addItemWithTitle:title];
    }
    [_stylePopup setTarget:self];
    [_stylePopup setAction:@selector(styleChanged:)];
    [self.view addSubview:_stylePopup];
    y += 28;

    _styleHint = [self createLabel:@"" at:NSMakePoint(controlX + 3, y)];
    _styleHint.frame = NSMakeRect(controlX + 3, y, 300, 17);
    _styleHint.textColor = [NSColor secondaryLabelColor];
    [self.view addSubview:_styleHint];
    y += 26;

    // Channels
    [self.view addSubview:[self createLabel:@"Channels:" at:NSMakePoint(labelX + 10, y + 3)]];
    _channelsPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 150, 25)];
    [_channelsPopup addItemWithTitle:@"Stereo (L / R)"];
    [_channelsPopup addItemWithTitle:@"Mono (mixed)"];
    _channelsPopup.toolTip = @"Left and right apart, or both mixed into one waveform";
    [_channelsPopup setTarget:self];
    [_channelsPopup setAction:@selector(channelsChanged:)];
    [self.view addSubview:_channelsPopup];
    y += 32;

    // Played part opacity (the part still to play is opaque)
    [self.view addSubview:[self createLabel:@"Played opacity:" at:NSMakePoint(labelX + 10, y + 3)]];
    _playedOpacitySlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, 150, 22)];
    _playedOpacitySlider.minValue = waveform_config::kMinPlayedOpacity;
    _playedOpacitySlider.maxValue = waveform_config::kMaxPlayedOpacity;
    _playedOpacitySlider.continuous = YES;
    _playedOpacitySlider.toolTip = @"How strongly the part already played is drawn";
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

    // Elapsed time on the cursor
    _cursorTimeCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 250, 20)];
    _cursorTimeCheckbox.buttonType = NSButtonTypeSwitch;
    _cursorTimeCheckbox.title = @"Elapsed time on the cursor";
    [_cursorTimeCheckbox setTarget:self];
    [_cursorTimeCheckbox setAction:@selector(checkboxChanged:)];
    [self.view addSubview:_cursorTimeCheckbox];
    y += 26;

    // Glass background
    _glassBackgroundCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 250, 20)];
    _glassBackgroundCheckbox.buttonType = NSButtonTypeSwitch;
    _glassBackgroundCheckbox.title = @"Glass background";
    _glassBackgroundCheckbox.toolTip = @"Translucent blur background instead of a solid color";
    [_glassBackgroundCheckbox setTarget:self];
    [_glassBackgroundCheckbox setAction:@selector(checkboxChanged:)];
    [self.view addSubview:_glassBackgroundCheckbox];
    y += 32;

    // Theme (a preset for all four colors below)
    [self.view addSubview:[self createLabel:@"Theme:" at:NSMakePoint(labelX + 10, y + 3)]];
    _themePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 160, 25)];
    for (int index : waveform_config::kThemeMenuOrder) {
        [_themePopup addItemWithTitle:[NSString stringWithUTF8String:waveform_config::kThemes[index].name]];
        _themePopup.lastItem.tag = index;
    }
    _themePopup.toolTip = @"A color preset for the waveform and background";
    [_themePopup setTarget:self];
    [_themePopup setAction:@selector(themeChanged:)];
    [self.view addSubview:_themePopup];
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

    // Overlays section
    [self.view addSubview:[self createLabel:@"Overlays" at:NSMakePoint(labelX, y)]];
    y += 22;

    _readoutCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 300, 20)];
    _readoutCheckbox.buttonType = NSButtonTypeSwitch;
    _readoutCheckbox.title = @"Readout on hover";
    _readoutCheckbox.toolTip = @"Time, LUFS-S, peak, crest, correlation, band split";
    [_readoutCheckbox setTarget:self];
    [_readoutCheckbox setAction:@selector(checkboxChanged:)];
    [self.view addSubview:_readoutCheckbox];
    y += 26;

    [self.view addSubview:[self createLabel:@"Loudness summary:" at:NSMakePoint(labelX + 10, y + 3)]];
    _summaryPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX + 20, y, 130, 25)];
    [_summaryPopup addItemWithTitle:@"Off"];
    [_summaryPopup addItemWithTitle:@"On hover"];
    [_summaryPopup addItemWithTitle:@"Always"];
    _summaryPopup.toolTip = @"Integrated, LRA, true peak, PLR, clip count";
    [_summaryPopup setTarget:self];
    [_summaryPopup setAction:@selector(summaryChanged:)];
    [self.view addSubview:_summaryPopup];
    y += 30;

    _clipMarkersCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 300, 20)];
    _clipMarkersCheckbox.buttonType = NSButtonTypeSwitch;
    _clipMarkersCheckbox.title = @"Clip markers";
    _clipMarkersCheckbox.toolTip = @"Runs of 3+ samples at full scale";
    [_clipMarkersCheckbox setTarget:self];
    [_clipMarkersCheckbox setAction:@selector(checkboxChanged:)];
    [self.view addSubview:_clipMarkersCheckbox];
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

    // Checkboxes
    _glassBackgroundCheckbox.state = getConfigBool(kKeyGlassBackground, kDefaultGlassBackground) ? NSControlStateValueOn : NSControlStateValueOff;

    [self loadColors];

    // Style
    const int64_t style = getConfigInt(kKeyStyle, kDefaultStyle);
    [_stylePopup selectItemAtIndex:(style >= 0 && style < StyleCount) ? style : kDefaultStyle];
    [self updateStyleHint];
    [_channelsPopup selectItemAtIndex:getConfigInt(kKeyChannelMode, kDefaultChannelMode) == ChannelsMono ? 1 : 0];

    // Played part opacity and cursor time
    const int64_t opacity = std::clamp<int64_t>(getConfigInt(kKeyPlayedOpacity, kDefaultPlayedOpacity),
                                                kMinPlayedOpacity, kMaxPlayedOpacity);
    _playedOpacitySlider.integerValue = opacity;
    _playedOpacityLabel.stringValue = [NSString stringWithFormat:@"%lld%%", opacity];
    _cursorTimeCheckbox.state = getConfigBool(kKeyCursorTime, kDefaultCursorTime) ? NSControlStateValueOn : NSControlStateValueOff;

    // Overlays
    _readoutCheckbox.state = getConfigBool(kKeyHoverReadout, kDefaultHoverReadout) ? NSControlStateValueOn : NSControlStateValueOff;
    [_summaryPopup selectItemAtIndex:std::clamp<int64_t>(getConfigInt(kKeySummaryMode, kDefaultSummaryMode), SummaryOff, SummaryAlways)];
    _clipMarkersCheckbox.state = getConfigBool(kKeyClipMarkers, kDefaultClipMarkers) ? NSControlStateValueOn : NSControlStateValueOff;

    // Cache settings
    _cacheSizeField.integerValue = getConfigInt(kKeyCacheSizeMB, kDefaultCacheSizeMB);
    _retentionField.integerValue = getConfigInt(kKeyCacheRetentionDays, kDefaultCacheRetentionDays);
}

// Color wells and the theme popup, which shows the preset matching them
- (void)loadColors {
    using namespace waveform_config;

    // Light mode colors
    _waveColorLightWell.color = [self colorFromARGB:static_cast<uint32_t>(getConfigInt(kKeyWaveColorLight, kDefaultWaveColorLight))];
    _bgColorLightWell.color = [self colorFromARGB:static_cast<uint32_t>(getConfigInt(kKeyBgColorLight, kDefaultBgColorLight))];

    // Dark mode colors
    _waveColorDarkWell.color = [self colorFromARGB:static_cast<uint32_t>(getConfigInt(kKeyWaveColorDark, kDefaultWaveColorDark))];
    _bgColorDarkWell.color = [self colorFromARGB:static_cast<uint32_t>(getConfigInt(kKeyBgColorDark, kDefaultBgColorDark))];

    [_themePopup selectItemWithTag:themeMatchingConfig()];
}

- (NSColor *)colorFromARGB:(uint32_t)argb {
    waveseek::Rgba color = waveseek::rgbaFromArgb(argb);
    return [NSColor colorWithRed:color.r green:color.g blue:color.b alpha:color.a];
}

- (uint32_t)argbFromColor:(NSColor *)color {
    NSColor *rgbColor = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!rgbColor) return 0xFF000000;

    return waveseek::argbFromRgba({rgbColor.redComponent, rgbColor.greenComponent,
                                   rgbColor.blueComponent, rgbColor.alphaComponent});
}

- (void)updateCacheStatus {
    auto stats = getWaveformService().getCacheStats();

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

- (void)updateStyleHint {
    static NSString *const hints[] = {
        @"Peak envelope around a short-term loudness body, one dBFS axis.",
        @"Split L/R lanes, linear peak at 50 % with an RMS core.",
        @"Split L/R lanes, peaks fade to the tips, hot RMS core.",
        @"Split L/R lanes, colour by amplitude: deep → accent → hot.",
    };
    const NSInteger i = _stylePopup.indexOfSelectedItem;
    _styleHint.stringValue = (i >= 0 && i < waveform_config::StyleCount) ? hints[i] : @"";
}

- (void)styleChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeyStyle, _stylePopup.indexOfSelectedItem);
    [self updateStyleHint];
    [self notifySettingsChanged];
}

- (void)channelsChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeyChannelMode, _channelsPopup.indexOfSelectedItem == 1 ? ChannelsMono : ChannelsStereo);
    [self notifySettingsChanged];
}

- (void)summaryChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeySummaryMode, _summaryPopup.indexOfSelectedItem);
    [self notifySettingsChanged];
}

- (void)checkboxChanged:(id)sender {
    using namespace waveform_config;
    if (sender == _glassBackgroundCheckbox) {
        setConfigBool(kKeyGlassBackground, _glassBackgroundCheckbox.state == NSControlStateValueOn);
    } else if (sender == _cursorTimeCheckbox) {
        setConfigBool(kKeyCursorTime, _cursorTimeCheckbox.state == NSControlStateValueOn);
    } else if (sender == _readoutCheckbox) {
        setConfigBool(kKeyHoverReadout, _readoutCheckbox.state == NSControlStateValueOn);
    } else if (sender == _clipMarkersCheckbox) {
        setConfigBool(kKeyClipMarkers, _clipMarkersCheckbox.state == NSControlStateValueOn);
    }
    [self notifySettingsChanged];
}

- (void)themeChanged:(id)sender {
    waveform_config::applyThemeToConfig((int)_themePopup.selectedTag);   // no-op for Custom
    [self loadColors];
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
    [_themePopup selectItemWithTag:themeMatchingConfig()];
    [self notifySettingsChanged];
}

- (void)opacityChanged:(id)sender {
    using namespace waveform_config;
    NSInteger value = _playedOpacitySlider.integerValue;
    setConfigInt(kKeyPlayedOpacity, value);
    _playedOpacityLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)value];
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
        getWaveformService().clearCache();
        [self updateCacheStatus];
    }
}

- (void)showComponentInfo:(NSButton *)sender {
    JLShowComponentInfo(sender, JLComponentInfoRows());
}

@end

// Preferences page registration
namespace {
    class waveform_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            return fb2k::wrapNSObject([[WaveformPreferences alloc] init]);
        }

        const char* get_name() override {
            return "Waveform Seekbar";
        }

        GUID get_guid() override {
            return waveform_config::guid_preferences_page;
        }

        GUID get_parent_guid() override {
            return preferences_page::guid_display;
        }
    };

    FB2K_SERVICE_FACTORY(waveform_preferences_page);
}
