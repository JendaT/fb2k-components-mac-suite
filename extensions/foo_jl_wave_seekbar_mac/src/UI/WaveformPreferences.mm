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

namespace {
// Two columns of cards: Appearance on the left, Overlays and Scales on the
// right, Cache across the bottom
const CGFloat kPageWidth = 660.0;
const CGFloat kMargin = 20.0;
const CGFloat kColumnGap = 16.0;
const CGFloat kColumnWidth = (kPageWidth - 2 * kMargin - kColumnGap) / 2;
const CGFloat kCardGap = 16.0;
const CGFloat kCardPad = 14.0;
const CGFloat kRowGap = 12.0;
const CGFloat kHintIndent = 20.0;   // under a checkbox's title
}

@interface WaveformPreferences () {
    WaveformFlippedView *_page;

    // Appearance
    NSPopUpButton *_stylePopup;
    NSTextField *_styleHint;
    NSPopUpButton *_bodyTintPopup;
    NSPopUpButton *_gradientBandsPopup;
    NSPopUpButton *_channelsPopup;
    NSPopUpButton *_themePopup;
    NSColorWell *_waveColorLightWell;
    NSColorWell *_bgColorLightWell;
    NSColorWell *_waveColorDarkWell;
    NSColorWell *_bgColorDarkWell;
    NSSlider *_playedOpacitySlider;
    NSTextField *_playedOpacityLabel;
    NSButton *_glassBackgroundCheckbox;

    // Overlays
    NSPopUpButton *_textSizePopup;
    NSButton *_readoutCheckbox;
    NSPopUpButton *_readoutPositionPopup;
    NSButton *_cursorTimeCheckbox;
    NSPopUpButton *_summaryPopup;
    NSButton *_clipMarkersCheckbox;

    // Scales
    NSButton *_timeRulerCheckbox;
    NSButton *_levelScaleCheckbox;

    // Cache
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
    // The page scrolls when the preferences window is shorter than it
    _page = [[WaveformFlippedView alloc] initWithFrame:NSMakeRect(0, 0, kPageWidth, 600)];
    _page.autoresizingMask = 0;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, kPageWidth, 600)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.documentView = _page;
    self.view = scrollView;

    // Allow transparent colors (alpha slider in the color panel)
    [NSColor setIgnoresAlpha:NO];
    [NSColorPanel sharedColorPanel].showsAlpha = YES;

    [self buildUI];
    [self loadSettings];
}

#pragma mark - Layout helpers

// A card's box goes in behind controls already laid out from `top` to `bottom`
- (CGFloat)closeCardAtX:(CGFloat)x top:(CGFloat)top bottom:(CGFloat)bottom width:(CGFloat)width {
    NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(x, top, width, bottom + kCardPad - top)];
    box.boxType = NSBoxCustom;
    box.titlePosition = NSNoTitle;
    box.cornerRadius = 8.0;
    box.borderWidth = 1.0;
    box.borderColor = [NSColor separatorColor];
    box.fillColor = [[NSColor labelColor] colorWithAlphaComponent:0.035];
    [_page addSubview:box positioned:NSWindowBelow relativeTo:nil];
    return NSMaxY(box.frame);
}

- (CGFloat)addCardTitle:(NSString *)title x:(CGFloat)x y:(CGFloat)y {
    NSTextField *label = [NSTextField labelWithAttributedString:[[NSAttributedString alloc]
        initWithString:title.uppercaseString
            attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                          NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
                          NSKernAttributeName: @0.6 }]];
    [label sizeToFit];
    label.frameOrigin = NSMakePoint(x, y);
    [_page addSubview:label];
    return y + label.frame.size.height + 10;
}

- (CGFloat)addHeading:(NSString *)text x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:13];
    label.frame = NSMakeRect(x, y, width, 17);
    [_page addSubview:label];
    return y + 21;
}

// One-line description, wrapped to the width; `lines` reserves height for
// text that changes
- (NSTextField *)addHint:(NSString *)text x:(CGFloat)x y:(CGFloat *)y width:(CGFloat)width lines:(int)lines {
    NSTextField *hint = [NSTextField wrappingLabelWithString:text];
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.preferredMaxLayoutWidth = width;
    CGFloat height = [hint.cell cellSizeForBounds:NSMakeRect(0, 0, width, 1000)].height;
    height = std::max(height, (CGFloat)lines * 14.0);
    hint.frame = NSMakeRect(x, *y, width, height);
    [_page addSubview:hint];
    *y += height;
    return hint;
}

- (NSPopUpButton *)addPopup:(NSArray<NSString *> *)titles action:(SEL)action x:(CGFloat)x y:(CGFloat *)y width:(CGFloat)width {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x - 2, *y, width + 4, 26) pullsDown:NO];
    [popup addItemsWithTitles:titles];
    popup.target = self;
    popup.action = action;
    [_page addSubview:popup];
    *y += 30;
    return popup;
}

- (NSButton *)addCheckbox:(NSString *)title hint:(NSString *)hint x:(CGFloat)x y:(CGFloat *)y width:(CGFloat)width {
    NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(checkboxChanged:)];
    box.font = [NSFont systemFontOfSize:13];
    box.frame = NSMakeRect(x, *y, width, 18);
    [_page addSubview:box];
    *y += 21;
    [self addHint:hint x:x + kHintIndent y:y width:width - kHintIndent lines:1];
    *y += kRowGap;
    return box;
}

- (NSTextField *)addSmallLabel:(NSString *)text frame:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:11];
    label.frame = frame;
    [_page addSubview:label];
    return label;
}

#pragma mark - Cards

- (void)buildUI {
    CGFloat y = 10;
    NSTextField *title = JLCreatePreferencesTitle(@"Waveform Seekbar");
    title.frame = NSMakeRect(kMargin, y, 400, 20);
    [_page addSubview:title];
    JLAddPreferencesInfoButton(_page, title, self, @selector(showComponentInfo:));
    y += 32;

    const CGFloat rightX = kMargin + kColumnWidth + kColumnGap;
    const CGFloat left = [self buildAppearanceAtX:kMargin y:y];
    CGFloat right = [self buildOverlaysAtX:rightX y:y];
    right = [self buildScalesAtX:rightX y:right + kCardGap];
    y = std::max(left, right) + kCardGap;
    y = [self buildCacheAtX:kMargin y:y width:kPageWidth - 2 * kMargin];

    _page.frame = NSMakeRect(0, 0, kPageWidth, y + kMargin);
    [self updateCacheStatus];
}

- (CGFloat)buildAppearanceAtX:(CGFloat)cardX y:(CGFloat)top {
    const CGFloat x = cardX + kCardPad, w = kColumnWidth - 2 * kCardPad;
    CGFloat y = [self addCardTitle:@"Appearance" x:x y:top + kCardPad];

    y = [self addHeading:@"Style" x:x y:y width:w];
    _stylePopup = [self addPopup:@[ @"Layered — peak + loudness (dBFS)", @"Simple — Two-tone",
                                    @"Simple — Glow", @"Simple — Heat",
                                    @"Classic — Heat map", @"Classic — Rainbow", @"Classic — Solid" ]
                          action:@selector(styleChanged:) x:x y:&y width:w];
    _styleHint = [self addHint:@"" x:x y:&y width:w lines:2];
    y += kRowGap;

    y = [self addHeading:@"Body tint" x:x y:y width:w];
    _bodyTintPopup = [self addPopup:@[ @"Off", @"Subtle", @"Strong" ]
                             action:@selector(bodyTintChanged:) x:x y:&y width:w];
    [self addHint:@"Layered: the body darker where bass dominates, lighter where highs do."
                x:x y:&y width:w lines:1];
    y += kRowGap;

    y = [self addHeading:@"Gradient bands" x:x y:y width:w];
    _gradientBandsPopup = [self addPopup:@[] action:@selector(gradientBandsChanged:) x:x y:&y width:w];
    for (int bands : waveform_config::kGradientBandChoices) {
        [_gradientBandsPopup addItemWithTitle:bands == 0 ? @"None (flat)" : [NSString stringWithFormat:@"%d", bands]];
        _gradientBandsPopup.lastItem.tag = bands;
    }
    [self addHint:@"Classic Solid: steps from the centre out; more steps fade more smoothly."
                x:x y:&y width:w lines:1];
    y += kRowGap;

    y = [self addHeading:@"Channels" x:x y:y width:w];
    _channelsPopup = [self addPopup:@[ @"Stereo (L / R)", @"Mono (mixed)" ]
                             action:@selector(channelsChanged:) x:x y:&y width:w];
    [self addHint:@"Left and right apart, or both mixed into one waveform." x:x y:&y width:w lines:1];
    y += kRowGap;

    // Theme presets, and the four colours they set
    y = [self addHeading:@"Colours" x:x y:y width:w];
    _themePopup = [self addPopup:@[] action:@selector(themeChanged:) x:x y:&y width:w];
    for (int index : waveform_config::kThemeMenuOrder) {
        [_themePopup addItemWithTitle:[NSString stringWithUTF8String:waveform_config::kThemes[index].name]];
        _themePopup.lastItem.tag = index;
    }
    NSColorWell *__strong *wells[2][2] = { { &_waveColorLightWell, &_bgColorLightWell },
                                            { &_waveColorDarkWell, &_bgColorDarkWell } };
    NSString *modes[2] = { @"Light mode", @"Dark mode" };
    for (int m = 0; m < 2; ++m) {
        [self addSmallLabel:modes[m] frame:NSMakeRect(x, y + 4, 70, 15)];
        CGFloat wx = x + 72;
        NSString *captions[2] = { @"Wave", @"Background" };
        for (int c = 0; c < 2; ++c) {
            *wells[m][c] = [self createColorWellAt:NSMakePoint(wx, y)];
            [_page addSubview:*wells[m][c]];
            [self addSmallLabel:captions[c] frame:NSMakeRect(wx + 40, y + 4, 70, 15)];
            wx += c == 0 ? 82 : 0;
        }
        y += 28;
    }
    [self addHint:@"Editing a colour switches Colours to Custom." x:x y:&y width:w lines:1];
    y += kRowGap;

    // Played part opacity, value at the right of its heading
    [self addHeading:@"Played opacity" x:x y:y width:w];
    _playedOpacityLabel = [NSTextField labelWithString:@""];
    _playedOpacityLabel.font = [NSFont systemFontOfSize:13];
    _playedOpacityLabel.textColor = [NSColor secondaryLabelColor];
    _playedOpacityLabel.alignment = NSTextAlignmentRight;
    _playedOpacityLabel.frame = NSMakeRect(x + w - 60, y, 60, 17);
    [_page addSubview:_playedOpacityLabel];
    y += 21;
    _playedOpacitySlider = [NSSlider sliderWithValue:waveform_config::kDefaultPlayedOpacity
                                            minValue:waveform_config::kMinPlayedOpacity
                                            maxValue:waveform_config::kMaxPlayedOpacity
                                              target:self action:@selector(opacityChanged:)];
    _playedOpacitySlider.continuous = YES;
    _playedOpacitySlider.frame = NSMakeRect(x, y, w, 22);
    [_page addSubview:_playedOpacitySlider];
    y += 26;
    [self addHint:@"How strongly the part already played is drawn; the rest is at full strength."
                x:x y:&y width:w lines:1];
    y += kRowGap;

    _glassBackgroundCheckbox = [self addCheckbox:@"Glass background"
                                            hint:@"Translucent blur behind the waveform instead of the background colour."
                                               x:x y:&y width:w];
    return [self closeCardAtX:cardX top:top bottom:y - kRowGap width:kColumnWidth];
}

- (CGFloat)buildOverlaysAtX:(CGFloat)cardX y:(CGFloat)top {
    const CGFloat x = cardX + kCardPad, w = kColumnWidth - 2 * kCardPad;
    CGFloat y = [self addCardTitle:@"Overlays" x:x y:top + kCardPad];

    y = [self addHeading:@"Text size" x:x y:y width:w];
    _textSizePopup = [self addPopup:@[] action:@selector(textSizeChanged:) x:x y:&y width:w];
    NSString *sizeNames[] = { @"Small", @"Medium", @"Large", @"Extra large" };
    for (size_t i = 0; i < std::size(waveform_config::kTextSizes); ++i) {
        [_textSizePopup addItemWithTitle:[NSString stringWithFormat:@"%@ (%d pt)", sizeNames[i],
                                                   waveform_config::kTextSizes[i]]];
        _textSizePopup.lastItem.tag = waveform_config::kTextSizes[i];
    }
    [self addHint:@"Readout, summary, cursor time and the scales' labels." x:x y:&y width:w lines:1];
    y += kRowGap;

    _readoutCheckbox = [self addCheckbox:@"Readout on hover"
                                    hint:@"Time, LUFS-S, peak, crest, correlation, band split; click to seek."
                                       x:x y:&y width:w];
    y -= kRowGap - 4;
    _readoutPositionPopup = [self addPopup:@[ @"Follows the mouse", @"Top right", @"Bottom right, above the summary" ]
                                    action:@selector(readoutPositionChanged:) x:x + kHintIndent y:&y
                                     width:w - kHintIndent];
    y += kRowGap - 4;
    _cursorTimeCheckbox = [self addCheckbox:@"Elapsed time on the cursor"
                                       hint:@"m:ss chip beside the playback cursor."
                                          x:x y:&y width:w];

    y = [self addHeading:@"Loudness summary" x:x y:y width:w];
    _summaryPopup = [self addPopup:@[ @"Off", @"On hover", @"Always" ]
                            action:@selector(summaryChanged:) x:x y:&y width:w];
    [self addHint:@"Integrated, LRA, true peak, PLR, clip count." x:x y:&y width:w lines:1];
    y += kRowGap;

    _clipMarkersCheckbox = [self addCheckbox:@"Clip markers"
                                        hint:@"Runs of 3+ samples at full scale, as ticks on the top edge."
                                           x:x y:&y width:w];
    return [self closeCardAtX:cardX top:top bottom:y - kRowGap width:kColumnWidth];
}

- (CGFloat)buildScalesAtX:(CGFloat)cardX y:(CGFloat)top {
    const CGFloat x = cardX + kCardPad, w = kColumnWidth - 2 * kCardPad;
    CGFloat y = [self addCardTitle:@"Scales" x:x y:top + kCardPad];

    _timeRulerCheckbox = [self addCheckbox:@"Time ruler below the waveform"
                                      hint:@"Ticks and m:ss labels; off gives the waveform full height."
                                         x:x y:&y width:w];
    _levelScaleCheckbox = [self addCheckbox:@"Level scale on the right"
                                       hint:@"dB labels in a gutter; off gives the waveform full width."
                                          x:x y:&y width:w];
    return [self closeCardAtX:cardX top:top bottom:y - kRowGap width:kColumnWidth];
}

- (CGFloat)buildCacheAtX:(CGFloat)cardX y:(CGFloat)top width:(CGFloat)width {
    const CGFloat x = cardX + kCardPad, w = width - 2 * kCardPad;
    CGFloat y = [self addCardTitle:@"Cache" x:x y:top + kCardPad];

    auto numberField = [&](CGFloat fx, CGFloat fw, int maximum) {
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(fx, y, fw, 22)];
        NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
        formatter.minimum = @1;
        formatter.maximum = @(maximum);
        field.formatter = formatter;
        field.target = self;
        field.action = @selector(cacheSettingChanged:);
        [_page addSubview:field];
        return field;
    };
    [self addSmallLabel:@"Max size" frame:NSMakeRect(x, y + 4, 52, 15)];
    _cacheSizeField = numberField(x + 54, 64, 10000);
    [self addSmallLabel:@"MB" frame:NSMakeRect(x + 122, y + 4, 24, 15)];
    [self addSmallLabel:@"Keep for" frame:NSMakeRect(x + 160, y + 4, 52, 15)];
    _retentionField = numberField(x + 214, 54, 3650);
    [self addSmallLabel:@"days" frame:NSMakeRect(x + 272, y + 4, 34, 15)];

    _clearCacheButton = [NSButton buttonWithTitle:@"Clear Cache" target:self action:@selector(clearCacheClicked:)];
    [_clearCacheButton sizeToFit];
    _clearCacheButton.frameOrigin = NSMakePoint(x + w - _clearCacheButton.frame.size.width, y - 3);
    [_page addSubview:_clearCacheButton];
    y += 28;

    _cacheStatusLabel = [self addHint:@"Cache: Loading..." x:x y:&y width:w lines:1];
    [self addHint:@"Analysis results per track; cleared tracks are analysed again when played."
                x:x y:&y width:w lines:1];
    return [self closeCardAtX:cardX top:top bottom:y width:width];
}

- (NSColorWell *)createColorWellAt:(NSPoint)point {
    NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(point.x, point.y, 36, 22)];
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
    [_gradientBandsPopup selectItemWithTag:getConfigInt(kKeyGradientBands, kDefaultGradientBands)];
    if (_gradientBandsPopup.indexOfSelectedItem < 0) [_gradientBandsPopup selectItemWithTag:kDefaultGradientBands];
    [_bodyTintPopup selectItemAtIndex:std::clamp<int64_t>(getConfigInt(kKeyBodyTint, kDefaultBodyTint),
                                                          BodyTintOff, BodyTintStrong)];
    [_channelsPopup selectItemAtIndex:getConfigInt(kKeyChannelMode, kDefaultChannelMode) == ChannelsMono ? 1 : 0];

    // Played part opacity and cursor time
    const int64_t opacity = std::clamp<int64_t>(getConfigInt(kKeyPlayedOpacity, kDefaultPlayedOpacity),
                                                kMinPlayedOpacity, kMaxPlayedOpacity);
    _playedOpacitySlider.integerValue = opacity;
    _playedOpacityLabel.stringValue = [NSString stringWithFormat:@"%lld%%", opacity];
    _cursorTimeCheckbox.state = getConfigBool(kKeyCursorTime, kDefaultCursorTime) ? NSControlStateValueOn : NSControlStateValueOff;

    // Overlays
    [_textSizePopup selectItemWithTag:getConfigInt(kKeyTextSize, kDefaultTextSize)];
    if (_textSizePopup.indexOfSelectedItem < 0) [_textSizePopup selectItemWithTag:kDefaultTextSize];
    _readoutCheckbox.state = getConfigBool(kKeyHoverReadout, kDefaultHoverReadout) ? NSControlStateValueOn : NSControlStateValueOff;
    [_readoutPositionPopup selectItemAtIndex:std::clamp<int64_t>(getConfigInt(kKeyReadoutPosition, kDefaultReadoutPosition),
                                                                 ReadoutFollowsMouse, ReadoutBottomRight)];
    _readoutPositionPopup.enabled = _readoutCheckbox.state == NSControlStateValueOn;
    [_summaryPopup selectItemAtIndex:std::clamp<int64_t>(getConfigInt(kKeySummaryMode, kDefaultSummaryMode), SummaryOff, SummaryAlways)];
    _clipMarkersCheckbox.state = getConfigBool(kKeyClipMarkers, kDefaultClipMarkers) ? NSControlStateValueOn : NSControlStateValueOff;

    // Scales
    _timeRulerCheckbox.state = getConfigBool(kKeyTimeRuler, kDefaultTimeRuler) ? NSControlStateValueOn : NSControlStateValueOff;
    _levelScaleCheckbox.state = getConfigBool(kKeyLevelScale, kDefaultLevelScale) ? NSControlStateValueOn : NSControlStateValueOff;

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
        @"Peak envelope around a loudness body tinted by the music's spectral balance, one dBFS axis.",
        @"Split L/R lanes, linear peak at 50 % with an RMS core.",
        @"Split L/R lanes, peaks fade to the tips, hot RMS core.",
        @"Split L/R lanes, colour by amplitude: deep → accent → hot.",
        @"Split L/R, each column coloured by its peak: blue → green → yellow → red.",
        @"Split L/R, colour runs through the rainbow across the track.",
        @"Split L/R, the theme colour fading from the centre out in steps.",
    };
    const NSInteger i = _stylePopup.indexOfSelectedItem;
    _styleHint.stringValue = (i >= 0 && i < waveform_config::StyleCount) ? hints[i] : @"";
    _bodyTintPopup.enabled = i == waveform_config::StyleLayered;
    _gradientBandsPopup.enabled = i == waveform_config::StyleSolid;
}

- (void)styleChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeyStyle, _stylePopup.indexOfSelectedItem);
    [self updateStyleHint];
    [self notifySettingsChanged];
}

- (void)gradientBandsChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeyGradientBands, _gradientBandsPopup.selectedTag);
    [self notifySettingsChanged];
}

- (void)bodyTintChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeyBodyTint, _bodyTintPopup.indexOfSelectedItem);
    [self notifySettingsChanged];
}

- (void)channelsChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeyChannelMode, _channelsPopup.indexOfSelectedItem == 1 ? ChannelsMono : ChannelsStereo);
    [self notifySettingsChanged];
}

- (void)textSizeChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeyTextSize, _textSizePopup.selectedTag);
    [self notifySettingsChanged];
}

- (void)readoutPositionChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeyReadoutPosition, _readoutPositionPopup.indexOfSelectedItem);
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
        _readoutPositionPopup.enabled = _readoutCheckbox.state == NSControlStateValueOn;
    } else if (sender == _clipMarkersCheckbox) {
        setConfigBool(kKeyClipMarkers, _clipMarkersCheckbox.state == NSControlStateValueOn);
    } else if (sender == _timeRulerCheckbox) {
        setConfigBool(kKeyTimeRuler, _timeRulerCheckbox.state == NSControlStateValueOn);
    } else if (sender == _levelScaleCheckbox) {
        setConfigBool(kKeyLevelScale, _levelScaleCheckbox.state == NSControlStateValueOn);
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
