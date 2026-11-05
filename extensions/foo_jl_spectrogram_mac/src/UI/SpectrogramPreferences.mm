//
//  SpectrogramPreferences.mm
//  foo_jl_spectrogram_mac
//
//  Preferences page, laid out in cards like the Waveform Seekbar's.
//

#import "SpectrogramPreferences.h"
#include "../fb2k_sdk.h"
#include "../Core/SpectrogramConfig.h"
#include "../Core/SpectrogramColormaps.h"
#include "../Core/SpectrogramThemes.h"
#include "../Core/SpectrogramEngine.h"
#import "../../../../shared/PreferencesCommon.h"
#import "../../../../shared/ThemeColor.h"
#include "../Integration/ComponentInfo.h"
#include <algorithm>

// Uniquely-named flipped view (avoids ObjC runtime clashes across components)
@interface SpectrogramFlippedView : NSView
@end
@implementation SpectrogramFlippedView
- (BOOL)isFlipped { return YES; }
@end

namespace {
// Two columns of cards: Analysis and Colours on the left, Display, Layout and
// Labels on the right
const CGFloat kPageWidth = 660.0;
const CGFloat kMargin = 20.0;
const CGFloat kColumnGap = 16.0;
const CGFloat kColumnWidth = (kPageWidth - 2 * kMargin - kColumnGap) / 2;
const CGFloat kCardGap = 16.0;
const CGFloat kCardPad = 14.0;
const CGFloat kRowGap = 12.0;
const CGFloat kHintIndent = 20.0;   // under a checkbox's title
}

@interface SpectrogramPreferences () {
    SpectrogramFlippedView *_page;

    // Analysis
    NSPopUpButton *_resolutionPopup;
    NSPopUpButton *_fftSizePopup;
    NSPopUpButton *_windowPopup;
    NSPopUpButton *_channelPopup;
    NSPopUpButton *_freqScalePopup;
    NSTextField   *_minHzField;
    NSTextField   *_maxHzField;

    // Colours
    NSPopUpButton *_colormapPopup;
    NSColorWell   *_customWells[spectrogram_colormap::kCustomColorCount];
    NSColorWell   *_bgColorLightWell;
    NSColorWell   *_bgColorDarkWell;
    NSColorWell   *_gridColorLightWell;
    NSColorWell   *_gridColorDarkWell;
    NSSlider      *_gridOpacitySlider;
    NSTextField   *_gridOpacityLabel;

    // Display
    NSSlider      *_topDbSlider;
    NSTextField   *_topDbLabel;
    NSSlider      *_rangeDbSlider;
    NSTextField   *_rangeDbLabel;
    NSPopUpButton *_slopePopup;
    NSPopUpButton *_scrollSpeedPopup;

    // Layout
    NSPopUpButton *_orientationPopup;
    NSButton      *_reverseCheckbox;
    NSPopUpButton *_fullScreenOrientationPopup;

    // Labels
    NSButton      *_freqAxisCheckbox;
    NSButton      *_legendCheckbox;
    NSPopUpButton *_freqFontPopup;
    NSPopUpButton *_dbFontPopup;
}
@end

@implementation SpectrogramPreferences

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (NSString *)preferencesTitle { return @"Spectrogram"; }

- (void)loadView {
    // The page scrolls when the preferences window is shorter than it
    _page = [[SpectrogramFlippedView alloc] initWithFrame:NSMakeRect(0, 0, kPageWidth, 600)];
    _page.autoresizingMask = 0;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, kPageWidth, 600)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.documentView = _page;
    self.view = scrollView;

    [NSColor setIgnoresAlpha:NO];
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

// Heading with its current value at the right, for a slider below it
- (NSTextField *)addHeading:(NSString *)text valueX:(CGFloat)x y:(CGFloat *)y width:(CGFloat)width {
    [self addHeading:text x:x y:*y width:width];
    NSTextField *value = [NSTextField labelWithString:@""];
    value.font = [NSFont systemFontOfSize:13];
    value.textColor = [NSColor secondaryLabelColor];
    value.alignment = NSTextAlignmentRight;
    value.frame = NSMakeRect(x + width - 70, *y, 70, 17);
    [_page addSubview:value];
    *y += 21;
    return value;
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

// Popup whose item tags hold the stored values
- (NSPopUpButton *)addTaggedPopup:(const std::vector<std::pair<NSString *, NSInteger>> &)items action:(SEL)action
                                x:(CGFloat)x y:(CGFloat *)y width:(CGFloat)width {
    NSPopUpButton *popup = [self addPopup:@[] action:action x:x y:y width:width];
    for (const auto &item : items) {
        [popup addItemWithTitle:item.first];
        popup.lastItem.tag = item.second;
    }
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

- (NSSlider *)addSliderMin:(double)lo max:(double)hi action:(SEL)action x:(CGFloat)x y:(CGFloat *)y width:(CGFloat)width {
    NSSlider *slider = [NSSlider sliderWithValue:lo minValue:lo maxValue:hi target:self action:action];
    slider.continuous = YES;
    slider.frame = NSMakeRect(x, *y, width, 22);
    [_page addSubview:slider];
    *y += 26;
    return slider;
}

- (NSTextField *)addSmallLabel:(NSString *)text frame:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:11];
    label.frame = frame;
    [_page addSubview:label];
    return label;
}

- (NSColorWell *)createColorWellAt:(NSPoint)point {
    NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(point.x, point.y, 36, 22)];
    well.target = self;
    well.action = @selector(colorChanged:);
    if (@available(macOS 13.0, *)) { well.colorWellStyle = NSColorWellStyleMinimal; }
    [_page addSubview:well];
    return well;
}

- (NSNumberFormatter *)intFormatterMin:(int)lo max:(int)hi {
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    f.numberStyle = NSNumberFormatterNoStyle;
    f.minimum = @(lo); f.maximum = @(hi);
    f.allowsFloats = NO;
    return f;
}

#pragma mark - Cards

- (void)buildUI {
    CGFloat y = 10;
    NSTextField *title = JLCreatePreferencesTitle(@"Spectrogram");
    title.frame = NSMakeRect(kMargin, y, 400, 20);
    [_page addSubview:title];
    JLAddPreferencesInfoButton(_page, title, self, @selector(showComponentInfo:));
    y += 32;

    const CGFloat rightX = kMargin + kColumnWidth + kColumnGap;
    CGFloat left = [self buildAnalysisAtX:kMargin y:y];
    left = [self buildColoursAtX:kMargin y:left + kCardGap];
    CGFloat right = [self buildDisplayAtX:rightX y:y];
    right = [self buildLayoutAtX:rightX y:right + kCardGap];
    right = [self buildLabelsAtX:rightX y:right + kCardGap];
    y = std::max(left, right);

    _page.frame = NSMakeRect(0, 0, kPageWidth, y + kMargin);
}

- (CGFloat)buildAnalysisAtX:(CGFloat)cardX y:(CGFloat)top {
    const CGFloat x = cardX + kCardPad, w = kColumnWidth - 2 * kCardPad;
    CGFloat y = [self addCardTitle:@"Analysis" x:x y:top + kCardPad];

    y = [self addHeading:@"Resolution" x:x y:y width:w];
    _resolutionPopup = [self addTaggedPopup:{ { @"Reassigned", SpectrogramEngine::ModeReassigned },
                                              { @"Multi-resolution", SpectrogramEngine::ModeMultiRes },
                                              { @"Standard", SpectrogramEngine::ModeStandard } }
                                     action:@selector(popupChanged:) x:x y:&y width:w];
    [self addHint:@"Reassigned: thin tonal lines and short kicks together. Multi-resolution: a 4x window "
                   "for bass, sharper lines but smeared kicks. Standard: one window everywhere."
                x:x y:&y width:w lines:3];
    y += kRowGap;

    y = [self addHeading:@"FFT size" x:x y:y width:w];
    _fftSizePopup = [self addPopup:@[ @"1024", @"2048", @"4096", @"8192", @"16384" ]
                            action:@selector(fftSizeChanged:) x:x y:&y width:w];
    [self addHint:@"At 44.1/48 kHz, scaled up at higher rates. Larger: finer pitch, blurrier timing."
                x:x y:&y width:w lines:2];
    y += kRowGap;

    y = [self addHeading:@"Window" x:x y:y width:w];
    _windowPopup = [self addPopup:@[ @"Hann", @"Blackman-Harris" ] action:@selector(popupChanged:) x:x y:&y width:w];
    [self addHint:@"Blackman-Harris keeps loud tones from smearing over quiet detail at wide dB ranges."
                x:x y:&y width:w lines:2];
    y += kRowGap;

    y = [self addHeading:@"Channel" x:x y:y width:w];
    // In spectrogram_config::Channel order
    _channelPopup = [self addPopup:@[ @"Mid (L + R)", @"Left", @"Right", @"Side (L − R)" ]
                            action:@selector(popupChanged:) x:x y:&y width:w];
    y += kRowGap;

    y = [self addHeading:@"Frequency scale" x:x y:y width:w];
    // In SpectrogramEngine::Scale order
    _freqScalePopup = [self addPopup:@[ @"Logarithmic", @"Mel", @"Linear" ] action:@selector(popupChanged:) x:x y:&y width:w];
    y += kRowGap;

    y = [self addHeading:@"Frequency range" x:x y:y width:w];
    _minHzField = [[NSTextField alloc] initWithFrame:NSMakeRect(x, y, 70, 22)];
    _minHzField.formatter = [self intFormatterMin:10 max:2000];
    _minHzField.target = self; _minHzField.action = @selector(rangeChanged:);
    [_page addSubview:_minHzField];
    [self addSmallLabel:@"to" frame:NSMakeRect(x + 78, y + 4, 18, 15)];
    _maxHzField = [[NSTextField alloc] initWithFrame:NSMakeRect(x + 98, y, 70, 22)];
    _maxHzField.formatter = [self intFormatterMin:1000 max:96000];
    _maxHzField.target = self; _maxHzField.action = @selector(rangeChanged:);
    [_page addSubview:_maxHzField];
    [self addSmallLabel:@"Hz" frame:NSMakeRect(x + 174, y + 4, 24, 15)];
    y += 28;
    [self addHint:@"Changing the scale or range clears the picture." x:x y:&y width:w lines:1];
    y += kRowGap;
    return [self closeCardAtX:cardX top:top bottom:y - kRowGap width:kColumnWidth];
}

- (CGFloat)buildColoursAtX:(CGFloat)cardX y:(CGFloat)top {
    using namespace spectrogram_colormap;
    const CGFloat x = cardX + kCardPad, w = kColumnWidth - 2 * kCardPad;
    CGFloat y = [self addCardTitle:@"Colours" x:x y:top + kCardPad];

    y = [self addHeading:@"Colormap" x:x y:y width:w];
    // Item tags hold the stored value (the map index, or kCustomMap); a
    // separator sets the Spectrum Analyzer theme ramps apart.
    _colormapPopup = [self addPopup:@[] action:@selector(colormapChanged:) x:x y:&y width:w];
    // Separators get a tag no map has: their default 0 is Inferno's index, and
    // selectItemWithTag: would pick the separator.
    auto addSeparator = [&] {
        NSMenuItem *separator = [NSMenuItem separatorItem];
        separator.tag = NSIntegerMin;
        [_colormapPopup.menu addItem:separator];
    };
    NSMenuItem *custom = [[NSMenuItem alloc] initWithTitle:@"Custom" action:nil keyEquivalent:@""];
    custom.tag = kCustomMap;
    [_colormapPopup.menu addItem:custom];
    addSeparator();
    for (int i = 0; i < kMapCount; ++i) {
        if (i == kFirstThemeMap) addSeparator();
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithUTF8String:kMaps[i].name]
                                                      action:nil
                                               keyEquivalent:@""];
        item.tag = i;
        [_colormapPopup.menu addItem:item];
    }

    // Custom ramp: floor (silence) up to peak (top level)
    static NSString *const kCustomNames[] = {@"Floor", @"Low", @"Mid", @"Peak"};
    for (int i = 0; i < kCustomColorCount; ++i) {
        const CGFloat wx = x + i * 56;
        _customWells[i] = [self createColorWellAt:NSMakePoint(wx, y)];
        _customWells[i].toolTip = [NSString stringWithFormat:@"%@ colour of the ramp", kCustomNames[i]];
        NSTextField *caption = [self addSmallLabel:kCustomNames[i] frame:NSMakeRect(wx, y + 24, 50, 14)];
        caption.textColor = [NSColor secondaryLabelColor];
    }
    y += 46;
    [self addHint:@"A preset fills in these colours; editing one switches to Custom. Theme ramps also "
                   "set the panel colours below."
                x:x y:&y width:w lines:2];
    y += kRowGap;

    // Panel colours: margins and gridlines, per appearance
    y = [self addHeading:@"Panel" x:x y:y width:w];
    NSColorWell *__strong *wells[2][2] = { { &_bgColorLightWell, &_gridColorLightWell },
                                            { &_bgColorDarkWell, &_gridColorDarkWell } };
    NSString *modes[2] = { @"Light mode", @"Dark mode" };
    for (int m = 0; m < 2; ++m) {
        [self addSmallLabel:modes[m] frame:NSMakeRect(x, y + 4, 70, 15)];
        CGFloat wx = x + 72;
        NSString *captions[2] = { @"Background", @"Grid" };
        for (int c = 0; c < 2; ++c) {
            *wells[m][c] = [self createColorWellAt:NSMakePoint(wx, y)];
            [self addSmallLabel:captions[c] frame:NSMakeRect(wx + 40, y + 4, 70, 15)];
            wx += 112;
        }
        y += 28;
    }
    [self addHint:@"Margins around the plot; labels take their colour from the background." x:x y:&y width:w lines:1];
    y += kRowGap;

    _gridOpacityLabel = [self addHeading:@"Grid opacity" valueX:x y:&y width:w];
    _gridOpacitySlider = [self addSliderMin:0 max:100 action:@selector(gridOpacityChanged:) x:x y:&y width:w];
    [self addHint:@"Lines across the plot at the labelled frequencies; 0% hides them." x:x y:&y width:w lines:1];
    y += kRowGap;
    return [self closeCardAtX:cardX top:top bottom:y - kRowGap width:kColumnWidth];
}

- (CGFloat)buildDisplayAtX:(CGFloat)cardX y:(CGFloat)top {
    const CGFloat x = cardX + kCardPad, w = kColumnWidth - 2 * kCardPad;
    CGFloat y = [self addCardTitle:@"Display" x:x y:top + kCardPad];

    _topDbLabel = [self addHeading:@"Top level" valueX:x y:&y width:w];
    _topDbSlider = [self addSliderMin:-40 max:0 action:@selector(topDbChanged:) x:x y:&y width:w];
    [self addHint:@"Level shown in the brightest colour. Lower it for quiet material." x:x y:&y width:w lines:1];
    y += kRowGap;

    _rangeDbLabel = [self addHeading:@"Range" valueX:x y:&y width:w];
    _rangeDbSlider = [self addSliderMin:40 max:140 action:@selector(rangeDbChanged:) x:x y:&y width:w];
    [self addHint:@"dB span below the top level. Smaller: more contrast, less quiet detail." x:x y:&y width:w lines:1];
    y += kRowGap;

    y = [self addHeading:@"Slope" x:x y:y width:w];
    std::vector<std::pair<NSString *, NSInteger>> slopes;   // tags: tenths of dB per octave
    for (int tenths : {0, 15, 30, 45, 60}) {
        slopes.emplace_back(tenths == 0 ? @"Off" : [NSString stringWithFormat:@"%g dB/octave", tenths / 10.0], tenths);
    }
    _slopePopup = [self addTaggedPopup:slopes action:@selector(popupChanged:) x:x y:&y width:w];
    [self addHint:@"Tilt around 1 kHz that brightens treble; the dB scale is then exact only at 1 kHz."
                x:x y:&y width:w lines:2];
    y += kRowGap;

    y = [self addHeading:@"Scroll speed" x:x y:y width:w];
    std::vector<std::pair<NSString *, NSInteger>> speeds;   // tags: points per second
    for (int speed : {30, 60, 120, 240}) {
        speeds.emplace_back([NSString stringWithFormat:@"%d pt/s", speed], speed);
    }
    _scrollSpeedPopup = [self addTaggedPopup:speeds action:@selector(popupChanged:) x:x y:&y width:w];
    y += kRowGap;
    return [self closeCardAtX:cardX top:top bottom:y - kRowGap width:kColumnWidth];
}

- (CGFloat)buildLayoutAtX:(CGFloat)cardX y:(CGFloat)top {
    using namespace spectrogram_config;
    const CGFloat x = cardX + kCardPad, w = kColumnWidth - 2 * kCardPad;
    CGFloat y = [self addCardTitle:@"Layout" x:x y:top + kCardPad];

    y = [self addHeading:@"Orientation" x:x y:y width:w];
    _orientationPopup = [self addTaggedPopup:{ { @"Horizontal — frequency along X", OrientationHorizontal },
                                               { @"Vertical — frequency along Y", OrientationVertical } }
                                      action:@selector(popupChanged:) x:x y:&y width:w];
    [self addHint:@"As in the Spectrum Analyzer: the same setting lines up their frequency axes."
                x:x y:&y width:w lines:2];
    y += kRowGap;

    _reverseCheckbox = [self addCheckbox:@"Reverse scroll direction"
                                    hint:@"New audio enters at the bottom (horizontal) or the left (vertical)."
                                       x:x y:&y width:w];

    y = [self addHeading:@"Full screen" x:x y:y width:w];
    _fullScreenOrientationPopup = [self addTaggedPopup:{ { @"Same as panel", kFullScreenSameAsPanel },
                                                         { @"Horizontal", OrientationHorizontal },
                                                         { @"Vertical", OrientationVertical } }
                                                action:@selector(popupChanged:) x:x y:&y width:w];
    [self addHint:@"Orientation of the full-screen view (double-click the spectrogram)."
                x:x y:&y width:w lines:1];
    y += kRowGap;
    return [self closeCardAtX:cardX top:top bottom:y - kRowGap width:kColumnWidth];
}

- (CGFloat)buildLabelsAtX:(CGFloat)cardX y:(CGFloat)top {
    using namespace spectrogram_config;
    const CGFloat x = cardX + kCardPad, w = kColumnWidth - 2 * kCardPad;
    CGFloat y = [self addCardTitle:@"Labels" x:x y:top + kCardPad];

    _freqAxisCheckbox = [self addCheckbox:@"Frequency axis"
                                     hint:@"Right of the plot (vertical) or below it (horizontal)."
                                        x:x y:&y width:w];
    _legendCheckbox = [self addCheckbox:@"dB colour scale"
                                   hint:@"Colour bar with its dB levels on the right."
                                      x:x y:&y width:w];

    // Two size popups side by side
    const CGFloat half = (w - 12) / 2;
    std::vector<std::pair<NSString *, NSInteger>> sizes;   // tags: points
    for (int size = kMinFontSize; size <= kMaxFontSize; ++size) {
        sizes.emplace_back([NSString stringWithFormat:@"%d pt", size], size);
    }
    [self addHeading:@"Frequency text" x:x y:y width:half];
    y = [self addHeading:@"dB text" x:x + half + 12 y:y width:half];
    CGFloat y2 = y;
    _freqFontPopup = [self addTaggedPopup:sizes action:@selector(popupChanged:) x:x y:&y width:half];
    _dbFontPopup = [self addTaggedPopup:sizes action:@selector(popupChanged:) x:x + half + 12 y:&y2 width:half];
    y += kRowGap;
    return [self closeCardAtX:cardX top:top bottom:y - kRowGap width:kColumnWidth];
}

- (void)showComponentInfo:(NSButton *)sender {
    JLShowComponentInfo(sender, JLComponentInfoRows());
}

#pragma mark - Load / persist

- (void)loadSettings {
    using namespace spectrogram_config;

    [self selectPopup:_fftSizePopup value:(int)getConfigInt(kKeyFftSize, kDefaultFftSize)];
    [self selectIndexPopup:_windowPopup index:getConfigInt(kKeyWindow, kDefaultWindow)];
    [self selectIndexPopup:_channelPopup index:getConfigInt(kKeyChannel, kDefaultChannel)];
    [self selectIndexPopup:_freqScalePopup index:getConfigInt(kKeyFreqScale, kDefaultFreqScale)];
    if (![_colormapPopup selectItemWithTag:getConfigInt(kKeyColormap, kDefaultColormap)])
        [_colormapPopup selectItemWithTag:kDefaultColormap];
    if (![_freqFontPopup selectItemWithTag:getConfigInt(kKeyFreqFontSize, kDefaultFreqFontSize)])
        [_freqFontPopup selectItemWithTag:kDefaultFreqFontSize];
    if (![_dbFontPopup selectItemWithTag:getConfigInt(kKeyDbFontSize, kDefaultDbFontSize)])
        [_dbFontPopup selectItemWithTag:kDefaultDbFontSize];
    [self reloadColorWells];
    if (![_slopePopup selectItemWithTag:getConfigInt(kKeySlopeTenths, kDefaultSlopeTenths)])
        [_slopePopup selectItemWithTag:kDefaultSlopeTenths];
    if (![_scrollSpeedPopup selectItemWithTag:getConfigInt(kKeyScrollSpeed, kDefaultScrollSpeed)])
        [_scrollSpeedPopup selectItemWithTag:kDefaultScrollSpeed];
    if (![_orientationPopup selectItemWithTag:getConfigInt(kKeyOrientation, kDefaultOrientation)])
        [_orientationPopup selectItemWithTag:kDefaultOrientation];
    _reverseCheckbox.state = getConfigBool(kKeyReverseScroll, kDefaultReverseScroll) ? NSControlStateValueOn : NSControlStateValueOff;
    if (![_fullScreenOrientationPopup selectItemWithTag:getConfigInt(kKeyFullScreenOrientation, kDefaultFullScreenOrientation)])
        [_fullScreenOrientationPopup selectItemWithTag:kDefaultFullScreenOrientation];

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

    if (![_resolutionPopup selectItemWithTag:getConfigInt(kKeyAnalysisMode, kDefaultAnalysisMode)])
        [_resolutionPopup selectItemWithTag:kDefaultAnalysisMode];
    _freqAxisCheckbox.state = getConfigBool(kKeyShowFreqAxis, kDefaultShowFreqAxis) ? NSControlStateValueOn : NSControlStateValueOff;
    _legendCheckbox.state = getConfigBool(kKeyShowLegend, kDefaultShowLegend) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)reloadColorWells {
    using namespace spectrogram_config;
    for (int i = 0; i < spectrogram_colormap::kCustomColorCount; ++i) {
        _customWells[i].color = [self colorFromARGB:customColor(i)];
    }
    _bgColorLightWell.color   = [self colorFromARGB:(uint32_t)getConfigInt(kKeyBgColorLight, kDefaultBgColorLight)];
    _bgColorDarkWell.color    = [self colorFromARGB:(uint32_t)getConfigInt(kKeyBgColorDark, kDefaultBgColorDark)];
    _gridColorLightWell.color = [self colorFromARGB:(uint32_t)getConfigInt(kKeyGridColorLight, kDefaultGridColorLight)];
    _gridColorDarkWell.color  = [self colorFromARGB:(uint32_t)getConfigInt(kKeyGridColorDark, kDefaultGridColorDark)];
}

// Stored colours are Display P3, matching how the view draws them.
- (NSColor *)colorFromARGB:(uint32_t)argb {
    return JLColorFromARGB(argb);
}

- (uint32_t)argbFromColor:(NSColor *)color {
    return JLARGBFromColor(color);
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
    if (sender == _resolutionPopup)       setConfigInt(kKeyAnalysisMode, _resolutionPopup.selectedItem.tag);
    else if (sender == _windowPopup)      setConfigInt(kKeyWindow, _windowPopup.indexOfSelectedItem);
    else if (sender == _channelPopup)     setConfigInt(kKeyChannel, _channelPopup.indexOfSelectedItem);
    else if (sender == _freqScalePopup)   setConfigInt(kKeyFreqScale, _freqScalePopup.indexOfSelectedItem);
    else if (sender == _freqFontPopup)    setConfigInt(kKeyFreqFontSize, _freqFontPopup.selectedItem.tag);
    else if (sender == _dbFontPopup)      setConfigInt(kKeyDbFontSize, _dbFontPopup.selectedItem.tag);
    else if (sender == _slopePopup)       setConfigInt(kKeySlopeTenths, _slopePopup.selectedItem.tag);
    else if (sender == _scrollSpeedPopup) setConfigInt(kKeyScrollSpeed, _scrollSpeedPopup.selectedItem.tag);
    else if (sender == _orientationPopup) setConfigInt(kKeyOrientation, _orientationPopup.selectedItem.tag);
    else if (sender == _fullScreenOrientationPopup) setConfigInt(kKeyFullScreenOrientation, _fullScreenOrientationPopup.selectedItem.tag);
    [self notifyChanged];
}

- (void)colormapChanged:(id)sender {
    using namespace spectrogram_config;
    const int index = (int)_colormapPopup.selectedItem.tag;
    setConfigInt(kKeyColormap, index);
    applyColormapToConfig(index);  // no-op for Custom
    [self reloadColorWells];
    [self notifyChanged];
}

- (void)colorChanged:(id)sender {
    using namespace spectrogram_config;
    for (int i = 0; i < spectrogram_colormap::kCustomColorCount; ++i) {
        if (sender != _customWells[i]) continue;
        setConfigInt(kKeyCustomColors[i], [self argbFromColor:_customWells[i].color]);
        // An edited ramp no longer matches a preset.
        setConfigInt(kKeyColormap, spectrogram_colormap::kCustomMap);
        [_colormapPopup selectItemWithTag:spectrogram_colormap::kCustomMap];
    }
    if (sender == _bgColorLightWell)        setConfigInt(kKeyBgColorLight, [self argbFromColor:_bgColorLightWell.color]);
    else if (sender == _bgColorDarkWell)    setConfigInt(kKeyBgColorDark, [self argbFromColor:_bgColorDarkWell.color]);
    else if (sender == _gridColorLightWell) setConfigInt(kKeyGridColorLight, [self argbFromColor:_gridColorLightWell.color]);
    else if (sender == _gridColorDarkWell)  setConfigInt(kKeyGridColorDark, [self argbFromColor:_gridColorDarkWell.color]);
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
    if (sender == _freqAxisCheckbox) {
        setConfigBool(kKeyShowFreqAxis, _freqAxisCheckbox.state == NSControlStateValueOn);
    } else if (sender == _reverseCheckbox) {
        setConfigBool(kKeyReverseScroll, _reverseCheckbox.state == NSControlStateValueOn);
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
