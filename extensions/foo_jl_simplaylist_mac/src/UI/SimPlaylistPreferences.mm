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
@property (nonatomic, strong) NSTextField *groupColumnPatternField;
@property (nonatomic, strong) NSTextField *subgroupPatternField;
@property (nonatomic, strong) NSSlider *albumArtSizeSlider;
@property (nonatomic, strong) NSTextField *albumArtSizeLabel;
@property (nonatomic, strong) NSArray<GroupPreset *> *presets;
@property (nonatomic, assign) NSInteger currentPresetIndex;
@end

@implementation SimPlaylistPreferencesController

- (void)loadView {
    // Use flipped view so y=0 is at top
    NSView *container = [[SimPlaylistFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 500, 400)];
    self.view = container;

    CGFloat y = 20;  // Start from top
    CGFloat labelWidth = 150;
    CGFloat fieldWidth = 300;
    CGFloat leftMargin = 20;
    CGFloat rowHeight = 28;

    // Title (non-bold, matches foobar2000 style)
    NSTextField *title = JLCreatePreferencesTitle(@"SimPlaylist Settings");
    title.frame = NSMakeRect(leftMargin, y, 400, 20);
    [container addSubview:title];
    y += 30;

    // Group Preset selector
    NSTextField *presetLabel = [NSTextField labelWithString:@"Grouping Preset:"];
    presetLabel.frame = NSMakeRect(leftMargin, y + 3, labelWidth, 20);
    [container addSubview:presetLabel];

    _presetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(leftMargin + labelWidth, y, fieldWidth, 26) pullsDown:NO];
    _presetPopup.target = self;
    _presetPopup.action = @selector(presetChanged:);
    [container addSubview:_presetPopup];
    y += rowHeight + 15;

    // Separator
    NSBox *sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(leftMargin, y, 460, 1)];
    sep1.boxType = NSBoxSeparator;
    [container addSubview:sep1];
    y += 15;

    // Header Pattern
    NSTextField *headerLabel = [NSTextField labelWithString:@"Header Pattern:"];
    headerLabel.frame = NSMakeRect(leftMargin, y + 2, labelWidth, 20);
    [container addSubview:headerLabel];

    _headerPatternField = [[NSTextField alloc] initWithFrame:NSMakeRect(leftMargin + labelWidth, y, fieldWidth, 22)];
    _headerPatternField.placeholderString = @"[%album artist% - ][%album%]";
    _headerPatternField.delegate = self;
    [container addSubview:_headerPatternField];
    y += rowHeight;

    // Group Column Pattern
    NSTextField *groupColLabel = [NSTextField labelWithString:@"Group Column:"];
    groupColLabel.frame = NSMakeRect(leftMargin, y + 2, labelWidth, 20);
    [container addSubview:groupColLabel];

    _groupColumnPatternField = [[NSTextField alloc] initWithFrame:NSMakeRect(leftMargin + labelWidth, y, fieldWidth, 22)];
    _groupColumnPatternField.placeholderString = @"[%album%]";
    _groupColumnPatternField.delegate = self;
    [container addSubview:_groupColumnPatternField];
    y += rowHeight;

    // Subgroup Pattern
    NSTextField *subgroupLabel = [NSTextField labelWithString:@"Subgroup Pattern:"];
    subgroupLabel.frame = NSMakeRect(leftMargin, y + 2, labelWidth, 20);
    [container addSubview:subgroupLabel];

    _subgroupPatternField = [[NSTextField alloc] initWithFrame:NSMakeRect(leftMargin + labelWidth, y, fieldWidth, 22)];
    _subgroupPatternField.placeholderString = @"[Disc %discnumber%]";
    _subgroupPatternField.delegate = self;
    [container addSubview:_subgroupPatternField];
    y += rowHeight + 15;

    // Separator
    NSBox *sep2 = [[NSBox alloc] initWithFrame:NSMakeRect(leftMargin, y, 460, 1)];
    sep2.boxType = NSBoxSeparator;
    [container addSubview:sep2];
    y += 15;

    // Album Art Size
    NSTextField *artSizeLabel = [NSTextField labelWithString:@"Album Art Size:"];
    artSizeLabel.frame = NSMakeRect(leftMargin, y + 2, labelWidth, 20);
    [container addSubview:artSizeLabel];

    _albumArtSizeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(leftMargin + labelWidth, y, 200, 20)];
    _albumArtSizeSlider.minValue = 40;
    _albumArtSizeSlider.maxValue = 300;
    _albumArtSizeSlider.target = self;
    _albumArtSizeSlider.action = @selector(albumArtSizeChanged:);
    [container addSubview:_albumArtSizeSlider];

    _albumArtSizeLabel = [NSTextField labelWithString:@"80 px"];
    _albumArtSizeLabel.frame = NSMakeRect(leftMargin + labelWidth + 210, y + 2, 60, 20);
    [container addSubview:_albumArtSizeLabel];
    y += rowHeight + 20;

    // Help text
    NSTextField *helpText = [[NSTextField alloc] initWithFrame:NSMakeRect(leftMargin, y, 460, 80)];
    helpText.stringValue = @"Title Format Patterns:\n"
        @"  %artist%, %album%, %title%, %tracknumber%, %date%\n"
        @"  %length%, %path%, %filename%\n"
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
        simplaylist_config::kGroupColumnWidth,
        simplaylist_config::kDefaultGroupColumnWidth);
    _albumArtSizeSlider.integerValue = artSize;
    _albumArtSizeLabel.stringValue = [NSString stringWithFormat:@"%lld px", artSize];
}

- (void)updateFieldsForPreset:(GroupPreset *)preset {
    _headerPatternField.stringValue = preset.headerPattern ?: @"";
    _groupColumnPatternField.stringValue = preset.groupColumnPattern ?: @"";
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
        preset.groupColumnPattern = _groupColumnPatternField.stringValue;
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
    // Real-time update as user types
    [self saveAndNotify];
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
