//
//  SimPlaylistPreferences.mm
//  foo_simplaylist_mac
//
//  Preferences page for SimPlaylist
//

#import "SimPlaylistPreferences.h"
#import "../Core/ConfigHelper.h"
#import "../Core/GroupPreset.h"
#import "../Core/ColumnDefinition.h"
#import "../fb2k_sdk.h"
#import "../../../../shared/PreferencesCommon.h"

// Flipped view for top-to-bottom layout (unique class name per extension)
@interface SimPlaylistFlippedView : NSView
@end
@implementation SimPlaylistFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface SimPlaylistPreferencesController () <NSTextFieldDelegate>
@property (nonatomic, strong) NSPopUpButton *presetPopup;
@property (nonatomic, strong) NSTextField *headerPatternField;
@property (nonatomic, strong) NSTextField *subgroupPatternField;
@property (nonatomic, strong) NSSlider *albumArtSizeSlider;
@property (nonatomic, strong) NSTextField *albumArtSizeLabel;
@property (nonatomic, strong) NSPopUpButton *headerStylePopup;
@property (nonatomic, strong) NSButton *nowPlayingShadingCheckbox;
@property (nonatomic, strong) NSButton *showFirstSubgroupCheckbox;
@property (nonatomic, strong) NSButton *hideSingleSubgroupCheckbox;
@property (nonatomic, strong) NSButton *dimParenthesesCheckbox;
@property (nonatomic, strong) NSPopUpButton *displaySizePopup;
@property (nonatomic, strong) NSArray<GroupPreset *> *presets;
@property (nonatomic, assign) NSInteger currentPresetIndex;
@end

@implementation SimPlaylistPreferencesController

- (void)loadView {
    // Use flipped view so y=0 is at top
    NSView *container = [[SimPlaylistFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 500, 520)];
    self.view = container;

    CGFloat y = 20;  // Start from top
    CGFloat labelWidth = 130;
    CGFloat fieldWidth = 280;
    CGFloat leftMargin = 20;
    CGFloat boxMargin = 15;
    CGFloat rowHeight = 26;

    // Title (non-bold, matches foobar2000 style)
    NSTextField *title = JLCreatePreferencesTitle(@"SimPlaylist Settings");
    title.frame = NSMakeRect(leftMargin, y, 400, 20);
    [container addSubview:title];
    y += 35;

    // ==================== GROUPING SETTINGS ====================
    CGFloat groupingBoxY = y;
    CGFloat groupingContentY = 22;  // Inside box, relative to box

    NSBox *groupingBox = [[NSBox alloc] initWithFrame:NSMakeRect(leftMargin, groupingBoxY, 460, 185)];
    groupingBox.title = @"Grouping Settings";
    groupingBox.titlePosition = NSAtTop;
    [container addSubview:groupingBox];

    NSView *groupingContent = [[SimPlaylistFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 440, 165)];
    groupingBox.contentView = groupingContent;

    // Preset selector
    NSTextField *presetLabel = [NSTextField labelWithString:@"Preset:"];
    presetLabel.frame = NSMakeRect(boxMargin, groupingContentY + 3, labelWidth, 20);
    [groupingContent addSubview:presetLabel];

    _presetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(boxMargin + labelWidth, groupingContentY, fieldWidth, 26) pullsDown:NO];
    _presetPopup.target = self;
    _presetPopup.action = @selector(presetChanged:);
    [groupingContent addSubview:_presetPopup];
    groupingContentY += rowHeight + 4;

    // Header Pattern
    NSTextField *headerLabel = [NSTextField labelWithString:@"Header Pattern:"];
    headerLabel.frame = NSMakeRect(boxMargin, groupingContentY + 2, labelWidth, 20);
    [groupingContent addSubview:headerLabel];

    _headerPatternField = [[NSTextField alloc] initWithFrame:NSMakeRect(boxMargin + labelWidth, groupingContentY, fieldWidth, 22)];
    _headerPatternField.placeholderString = @"[%album artist% - ][%album%]";
    _headerPatternField.delegate = self;
    [groupingContent addSubview:_headerPatternField];
    groupingContentY += rowHeight;

    // Subgroup Pattern
    NSTextField *subgroupLabel = [NSTextField labelWithString:@"Subgroup Pattern:"];
    subgroupLabel.frame = NSMakeRect(boxMargin, groupingContentY + 2, labelWidth, 20);
    [groupingContent addSubview:subgroupLabel];

    _subgroupPatternField = [[NSTextField alloc] initWithFrame:NSMakeRect(boxMargin + labelWidth, groupingContentY, fieldWidth, 22)];
    _subgroupPatternField.placeholderString = @"[Disc %discnumber%]";
    _subgroupPatternField.delegate = self;
    [groupingContent addSubview:_subgroupPatternField];
    groupingContentY += rowHeight;

    // Show First Subgroup Header
    _showFirstSubgroupCheckbox = [NSButton checkboxWithTitle:@"Show first subgroup header (e.g., Disc 1)"
                                                     target:self
                                                     action:@selector(showFirstSubgroupChanged:)];
    _showFirstSubgroupCheckbox.frame = NSMakeRect(boxMargin + labelWidth, groupingContentY, 280, 20);
    [groupingContent addSubview:_showFirstSubgroupCheckbox];
    groupingContentY += rowHeight;

    // Hide Single Subgroup
    _hideSingleSubgroupCheckbox = [NSButton checkboxWithTitle:@"Hide subgroups if only one in album"
                                                       target:self
                                                       action:@selector(hideSingleSubgroupChanged:)];
    _hideSingleSubgroupCheckbox.frame = NSMakeRect(boxMargin + labelWidth, groupingContentY, 280, 20);
    [groupingContent addSubview:_hideSingleSubgroupCheckbox];

    y = groupingBoxY + 195;

    // ==================== DISPLAY SETTINGS ====================
    CGFloat displayBoxY = y;
    CGFloat displayContentY = 22;

    NSBox *displayBox = [[NSBox alloc] initWithFrame:NSMakeRect(leftMargin, displayBoxY, 460, 220)];
    displayBox.title = @"Display Settings";
    displayBox.titlePosition = NSAtTop;
    [container addSubview:displayBox];

    NSView *displayContent = [[SimPlaylistFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 440, 170)];
    displayBox.contentView = displayContent;

    // Header Display Style
    NSTextField *headerStyleLabel = [NSTextField labelWithString:@"Header Display:"];
    headerStyleLabel.frame = NSMakeRect(boxMargin, displayContentY + 3, labelWidth, 20);
    [displayContent addSubview:headerStyleLabel];

    _headerStylePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(boxMargin + labelWidth, displayContentY, 200, 26) pullsDown:NO];
    [_headerStylePopup addItemWithTitle:@"Above tracks"];
    [_headerStylePopup addItemWithTitle:@"Album art aligned"];
    [_headerStylePopup addItemWithTitle:@"Inline (no header row)"];
    [_headerStylePopup addItemWithTitle:@"Under album art"];
    _headerStylePopup.target = self;
    _headerStylePopup.action = @selector(headerStyleChanged:);
    [displayContent addSubview:_headerStylePopup];
    displayContentY += rowHeight + 4;

    // Album Art Size
    NSTextField *artSizeLabel = [NSTextField labelWithString:@"Album Art Size:"];
    artSizeLabel.frame = NSMakeRect(boxMargin, displayContentY + 2, labelWidth, 20);
    [displayContent addSubview:artSizeLabel];

    _albumArtSizeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(boxMargin + labelWidth, displayContentY, 180, 20)];
    _albumArtSizeSlider.minValue = 40;
    _albumArtSizeSlider.maxValue = 300;
    _albumArtSizeSlider.target = self;
    _albumArtSizeSlider.action = @selector(albumArtSizeChanged:);
    [displayContent addSubview:_albumArtSizeSlider];

    _albumArtSizeLabel = [NSTextField labelWithString:@"80 px"];
    _albumArtSizeLabel.frame = NSMakeRect(boxMargin + labelWidth + 190, displayContentY + 2, 60, 20);
    [displayContent addSubview:_albumArtSizeLabel];
    displayContentY += rowHeight + 4;

    // Now Playing Shading
    _nowPlayingShadingCheckbox = [NSButton checkboxWithTitle:@"Highlight now playing row"
                                                     target:self
                                                     action:@selector(nowPlayingShadingChanged:)];
    _nowPlayingShadingCheckbox.frame = NSMakeRect(boxMargin + labelWidth, displayContentY, 250, 20);
    [displayContent addSubview:_nowPlayingShadingCheckbox];
    displayContentY += rowHeight;

    // Dim Parentheses
    _dimParenthesesCheckbox = [NSButton checkboxWithTitle:@"Dim text in parentheses () and []"
                                                  target:self
                                                  action:@selector(dimParenthesesChanged:)];
    _dimParenthesesCheckbox.frame = NSMakeRect(boxMargin + labelWidth, displayContentY, 280, 20);
    [displayContent addSubview:_dimParenthesesCheckbox];
    displayContentY += rowHeight + 4;

    // Display Size
    NSTextField *displaySizeLabel = [NSTextField labelWithString:@"Row Size:"];
    displaySizeLabel.frame = NSMakeRect(boxMargin, displayContentY + 3, labelWidth, 20);
    [displayContent addSubview:displaySizeLabel];

    _displaySizePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(boxMargin + labelWidth, displayContentY, 150, 26) pullsDown:NO];
    [_displaySizePopup addItemWithTitle:@"Compact"];
    [_displaySizePopup addItemWithTitle:@"Normal"];
    [_displaySizePopup addItemWithTitle:@"Large"];
    _displaySizePopup.target = self;
    _displaySizePopup.action = @selector(displaySizeChanged:);
    [displayContent addSubview:_displaySizePopup];

    y = displayBoxY + 230;

    // Help text
    NSTextField *helpText = [[NSTextField alloc] initWithFrame:NSMakeRect(leftMargin, y, 460, 60)];
    helpText.stringValue = @"Title Format Patterns:\n"
        @"  %artist%, %album%, %title%, %tracknumber%, %date%, %length%\n"
        @"  Use [...] for conditional display";
    helpText.editable = NO;
    helpText.bordered = NO;
    helpText.backgroundColor = [NSColor clearColor];
    helpText.font = [NSFont systemFontOfSize:11];
    helpText.textColor = [NSColor secondaryLabelColor];
    [container addSubview:helpText];

    // Load current settings
    [self loadSettings];
}

- (void)loadSettings {
    // Load presets
    _presets = [GroupPreset defaultPresets];
    _currentPresetIndex = simplaylist_config::getConfigInt(
        simplaylist_config::kActivePresetIndex, 0);

    [_presetPopup removeAllItems];
    for (GroupPreset *preset in _presets) {
        [_presetPopup addItemWithTitle:preset.name];
    }

    if (_currentPresetIndex >= 0 && _currentPresetIndex < (NSInteger)_presets.count) {
        [_presetPopup selectItemAtIndex:_currentPresetIndex];
        [self updateFieldsForPreset:_presets[_currentPresetIndex]];
    }

    // Load album art size
    int64_t artSize = simplaylist_config::getConfigInt(
        simplaylist_config::kAlbumArtSize,
        simplaylist_config::kDefaultAlbumArtSize);
    _albumArtSizeSlider.integerValue = artSize;
    _albumArtSizeLabel.stringValue = [NSString stringWithFormat:@"%lld px", artSize];

    // Load header display style
    int64_t headerStyle = simplaylist_config::getConfigInt(
        simplaylist_config::kHeaderDisplayStyle,
        simplaylist_config::kDefaultHeaderDisplayStyle);
    [_headerStylePopup selectItemAtIndex:headerStyle];

    // Load now playing shading
    bool nowPlayingShading = simplaylist_config::getConfigBool(
        simplaylist_config::kNowPlayingShading,
        simplaylist_config::kDefaultNowPlayingShading);
    _nowPlayingShadingCheckbox.state = nowPlayingShading ? NSControlStateValueOn : NSControlStateValueOff;

    // Load show first subgroup header
    bool showFirstSubgroup = simplaylist_config::getConfigBool(
        simplaylist_config::kShowFirstSubgroupHeader,
        simplaylist_config::kDefaultShowFirstSubgroupHeader);
    _showFirstSubgroupCheckbox.state = showFirstSubgroup ? NSControlStateValueOn : NSControlStateValueOff;

    // Load hide single subgroup
    bool hideSingleSubgroup = simplaylist_config::getConfigBool(
        simplaylist_config::kHideSingleSubgroup,
        simplaylist_config::kDefaultHideSingleSubgroup);
    _hideSingleSubgroupCheckbox.state = hideSingleSubgroup ? NSControlStateValueOn : NSControlStateValueOff;

    // Load dim parentheses
    bool dimParentheses = simplaylist_config::getConfigBool(
        simplaylist_config::kDimParentheses,
        simplaylist_config::kDefaultDimParentheses);
    _dimParenthesesCheckbox.state = dimParentheses ? NSControlStateValueOn : NSControlStateValueOff;

    // Load display size (0=compact, 1=normal, 2=large)
    int64_t displaySize = simplaylist_config::getConfigInt(
        simplaylist_config::kDisplaySize,
        simplaylist_config::kDefaultDisplaySize);
    [_displaySizePopup selectItemAtIndex:displaySize];
}

- (void)updateFieldsForPreset:(GroupPreset *)preset {
    _headerPatternField.stringValue = preset.headerPattern ?: @"";
    _subgroupPatternField.stringValue = preset.subgroupPattern ?: @"";
}

- (void)presetChanged:(id)sender {
    NSInteger index = _presetPopup.indexOfSelectedItem;
    if (index >= 0 && index < (NSInteger)_presets.count) {
        _currentPresetIndex = index;
        [self updateFieldsForPreset:_presets[index]];

        // Save selection
        simplaylist_config::setConfigInt(simplaylist_config::kActivePresetIndex, index);

        // Notify views to refresh
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistSettingsChanged"
                                                            object:nil];
    }
}

- (void)saveAndNotify {
    // Update the current preset from fields
    if (_currentPresetIndex >= 0 && _currentPresetIndex < (NSInteger)_presets.count) {
        GroupPreset *preset = _presets[_currentPresetIndex];
        preset.headerPattern = _headerPatternField.stringValue;
        preset.subgroupPattern = _subgroupPatternField.stringValue;

        // Save presets with correct active index
        NSString *json = [GroupPreset presetsToJSON:_presets activeIndex:_currentPresetIndex];
        if (json) {
            simplaylist_config::setConfigString(simplaylist_config::kGroupPresets, json.UTF8String);
        }

        // Notify views to refresh
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistSettingsChanged"
                                                            object:nil];
    }
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    [self saveAndNotify];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    // Debounce text changes to avoid rebuilding on every keystroke
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveAndNotify) object:nil];
    [self performSelector:@selector(saveAndNotify) withObject:nil afterDelay:0.5];
}

- (void)albumArtSizeChanged:(id)sender {
    NSInteger size = _albumArtSizeSlider.integerValue;
    _albumArtSizeLabel.stringValue = [NSString stringWithFormat:@"%ld px", (long)size];

    // Save album art size setting
    simplaylist_config::setConfigInt(simplaylist_config::kAlbumArtSize, size);

    // Also ensure column width is at least large enough to fit the art + padding
    int64_t currentColWidth = simplaylist_config::getConfigInt(
        simplaylist_config::kGroupColumnWidth,
        simplaylist_config::kDefaultGroupColumnWidth);
    int64_t minColWidth = size + 12;  // art size + padding on both sides
    if (currentColWidth < minColWidth) {
        simplaylist_config::setConfigInt(simplaylist_config::kGroupColumnWidth, minColWidth);
    }

    // Notify views to refresh
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistSettingsChanged"
                                                        object:nil];
}

- (void)headerStyleChanged:(id)sender {
    NSInteger style = _headerStylePopup.indexOfSelectedItem;
    simplaylist_config::setConfigInt(simplaylist_config::kHeaderDisplayStyle, style);

    // Notify views to refresh
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistSettingsChanged"
                                                        object:nil];
}

- (void)nowPlayingShadingChanged:(id)sender {
    bool enabled = (_nowPlayingShadingCheckbox.state == NSControlStateValueOn);
    simplaylist_config::setConfigBool(simplaylist_config::kNowPlayingShading, enabled);

    // Only needs redraw, not full rebuild
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistRedrawNeeded"
                                                        object:nil];
}

- (void)showFirstSubgroupChanged:(id)sender {
    bool enabled = (_showFirstSubgroupCheckbox.state == NSControlStateValueOn);
    simplaylist_config::setConfigBool(simplaylist_config::kShowFirstSubgroupHeader, enabled);

    // Notify views to refresh
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistSettingsChanged"
                                                        object:nil];
}

- (void)hideSingleSubgroupChanged:(id)sender {
    bool enabled = (_hideSingleSubgroupCheckbox.state == NSControlStateValueOn);
    simplaylist_config::setConfigBool(simplaylist_config::kHideSingleSubgroup, enabled);

    // Notify views to refresh (needs full rebuild to filter subgroups)
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistSettingsChanged"
                                                        object:nil];
}

- (void)dimParenthesesChanged:(id)sender {
    bool enabled = (_dimParenthesesCheckbox.state == NSControlStateValueOn);
    simplaylist_config::setConfigBool(simplaylist_config::kDimParentheses, enabled);

    // Only needs redraw, not full rebuild
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistRedrawNeeded"
                                                        object:nil];
}

- (void)displaySizeChanged:(id)sender {
    NSInteger size = _displaySizePopup.indexOfSelectedItem;
    simplaylist_config::setConfigInt(simplaylist_config::kDisplaySize, size);

    // Needs full rebuild because row height changes
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistSettingsChanged"
                                                        object:nil];
}

@end

#pragma mark - Preferences Page Registration

namespace {

// GUID for our preferences page
static const GUID guid_simplaylist_preferences =
    { 0x8a9e2c41, 0x3b7d, 0x4f52, { 0x9e, 0x1a, 0x5c, 0x8b, 0x3d, 0x6f, 0x4e, 0x2a } };

class simplaylist_preferences_page : public preferences_page_v2 {
public:
    const char* get_name() override {
        return "SimPlaylist";
    }

    GUID get_guid() override {
        return guid_simplaylist_preferences;
    }

    GUID get_parent_guid() override {
        return preferences_page::guid_display;  // Under Display in preferences
    }

    double get_sort_priority() override {
        return 0;
    }

    service_ptr instantiate() override {
        SimPlaylistPreferencesController *vc = [[SimPlaylistPreferencesController alloc] init];
        return fb2k::wrapNSObject(vc);
    }
};

FB2K_SERVICE_FACTORY(simplaylist_preferences_page);

} // namespace
