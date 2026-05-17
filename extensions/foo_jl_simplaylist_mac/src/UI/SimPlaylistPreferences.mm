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
#import "../Core/TitleFormatHelper.h"
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
@property (nonatomic, strong) NSTextField *headerPatternWarning;
@property (nonatomic, strong) NSTextField *subgroupPatternWarning;
@property (nonatomic, strong) NSTextField *headerPatternPreview;
@property (nonatomic, strong) NSTextField *subgroupPatternPreview;
@property (nonatomic, strong) NSSlider *albumArtSizeSlider;
@property (nonatomic, strong) NSTextField *albumArtSizeLabel;
@property (nonatomic, strong) NSPopUpButton *headerStylePopup;
@property (nonatomic, strong) NSButton *nowPlayingShadingCheckbox;
@property (nonatomic, strong) NSButton *showFirstSubgroupCheckbox;
@property (nonatomic, strong) NSButton *hideSingleSubgroupCheckbox;
@property (nonatomic, strong) NSButton *dimParenthesesCheckbox;
@property (nonatomic, strong) NSButton *showGroupDurationCheckbox;
@property (nonatomic, strong) NSPopUpButton *displaySizePopup;
@property (nonatomic, strong) NSPopUpButton *headerSizePopup;
@property (nonatomic, strong) NSPopUpButton *headerAccentPopup;
@property (nonatomic, strong) NSPopUpButton *groupHeaderSpacingPopup;
@property (nonatomic, strong) NSButton *glassBackgroundCheckbox;
@property (nonatomic, strong) NSButton *debugRenderingCheckbox;
@property (nonatomic, strong) NSButton *dragToFinderMoveCheckbox;
@property (nonatomic, strong) NSButton *preserveQueueCheckbox;
@property (nonatomic, strong) NSPopUpButton *queueDisplayStylePopup;
@property (nonatomic, strong) NSPopUpButton *finderOpenBehaviorPopup;
@property (nonatomic, strong) NSPopUpButton *finderOpenTargetPopup;
@property (nonatomic, assign) NSRect finderOpenTargetPopupFrame;
@property (nonatomic, weak)   NSView *finderOpenTargetPopupParent;
@property (nonatomic, strong) NSArray<GroupPreset *> *presets;
@property (nonatomic, assign) NSInteger currentPresetIndex;
@end

@implementation SimPlaylistPreferencesController

- (void)loadView {
    // Build the preferences inside a flipped container, then wrap it in a scroll view
    // so users can scroll if their preferences window is shorter than the content.
    NSView *container = [[SimPlaylistFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 820, 835)];
    container.autoresizingMask = 0;  // Fixed size so side-by-side layout stays intact

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 820, 600)];
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;  // fill host's allocated area
    scrollView.documentView = container;
    self.view = scrollView;

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

    // ==================== PATTERN HELP (side box) ====================
    {
        CGFloat helpX = leftMargin + 460 + 20;  // right of grouping box
        CGFloat helpW = 320;
        NSBox *helpBox = [[NSBox alloc] initWithFrame:NSMakeRect(helpX, groupingBoxY, helpW, 215)];
        helpBox.title = @"Pattern Help";
        helpBox.titlePosition = NSAtTop;
        [container addSubview:helpBox];

        NSView *helpContent = [[SimPlaylistFlippedView alloc] initWithFrame:NSMakeRect(0, 0, helpW - 20, 195)];
        helpBox.contentView = helpContent;

        CGFloat hy = 8;
        CGFloat hMargin = 10;
        CGFloat hW = helpW - 20 - 2 * hMargin;

        // Header pattern section
        NSTextField *hLabel = [NSTextField labelWithString:@"Header Pattern:"];
        hLabel.frame = NSMakeRect(hMargin, hy, hW, 16);
        hLabel.font = [NSFont boldSystemFontOfSize:11];
        [helpContent addSubview:hLabel];
        hy += 18;

        _headerPatternWarning = [NSTextField wrappingLabelWithString:@""];
        _headerPatternWarning.frame = NSMakeRect(hMargin, hy, hW, 28);
        _headerPatternWarning.font = [NSFont systemFontOfSize:10];
        _headerPatternWarning.textColor = [NSColor systemOrangeColor];
        _headerPatternWarning.hidden = YES;
        [helpContent addSubview:_headerPatternWarning];
        hy += 32;

        NSTextField *hPreviewLabel = [NSTextField labelWithString:@"Preview:"];
        hPreviewLabel.frame = NSMakeRect(hMargin, hy, hW, 14);
        hPreviewLabel.font = [NSFont systemFontOfSize:10];
        hPreviewLabel.textColor = [NSColor secondaryLabelColor];
        [helpContent addSubview:hPreviewLabel];
        hy += 14;

        _headerPatternPreview = [NSTextField wrappingLabelWithString:@""];
        _headerPatternPreview.frame = NSMakeRect(hMargin, hy, hW, 28);
        _headerPatternPreview.font = [NSFont systemFontOfSize:11];
        _headerPatternPreview.textColor = [NSColor labelColor];
        [helpContent addSubview:_headerPatternPreview];
        hy += 32;

        // Subgroup pattern section
        NSTextField *sLabel = [NSTextField labelWithString:@"Subgroup Pattern:"];
        sLabel.frame = NSMakeRect(hMargin, hy, hW, 16);
        sLabel.font = [NSFont boldSystemFontOfSize:11];
        [helpContent addSubview:sLabel];
        hy += 18;

        _subgroupPatternWarning = [NSTextField wrappingLabelWithString:@""];
        _subgroupPatternWarning.frame = NSMakeRect(hMargin, hy, hW, 14);
        _subgroupPatternWarning.font = [NSFont systemFontOfSize:10];
        _subgroupPatternWarning.textColor = [NSColor systemOrangeColor];
        _subgroupPatternWarning.hidden = YES;
        [helpContent addSubview:_subgroupPatternWarning];
        hy += 16;

        NSTextField *sPreviewLabel = [NSTextField labelWithString:@"Preview:"];
        sPreviewLabel.frame = NSMakeRect(hMargin, hy, hW, 14);
        sPreviewLabel.font = [NSFont systemFontOfSize:10];
        sPreviewLabel.textColor = [NSColor secondaryLabelColor];
        [helpContent addSubview:sPreviewLabel];
        hy += 14;

        _subgroupPatternPreview = [NSTextField wrappingLabelWithString:@""];
        _subgroupPatternPreview.frame = NSMakeRect(hMargin, hy, hW, 14);
        _subgroupPatternPreview.font = [NSFont systemFontOfSize:11];
        _subgroupPatternPreview.textColor = [NSColor labelColor];
        [helpContent addSubview:_subgroupPatternPreview];
    }

    y = groupingBoxY + 195;

    // ==================== DISPLAY SETTINGS ====================
    CGFloat displayBoxY = y;
    CGFloat displayContentY = 22;

    NSBox *displayBox = [[NSBox alloc] initWithFrame:NSMakeRect(leftMargin, displayBoxY, 460, 425)];
    displayBox.title = @"Display Settings";
    displayBox.titlePosition = NSAtTop;
    [container addSubview:displayBox];

    NSView *displayContent = [[SimPlaylistFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 440, 395)];
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
    displayContentY += rowHeight;

    // Show album duration in group header
    _showGroupDurationCheckbox = [NSButton checkboxWithTitle:@"Show album duration in group header"
                                                     target:self
                                                     action:@selector(showGroupDurationChanged:)];
    _showGroupDurationCheckbox.frame = NSMakeRect(boxMargin + labelWidth, displayContentY, 300, 20);
    [displayContent addSubview:_showGroupDurationCheckbox];
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
    displayContentY += rowHeight + 4;

    // Header Size
    NSTextField *headerSizeLabel = [NSTextField labelWithString:@"Header Size:"];
    headerSizeLabel.frame = NSMakeRect(boxMargin, displayContentY + 3, labelWidth, 20);
    [displayContent addSubview:headerSizeLabel];

    _headerSizePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(boxMargin + labelWidth, displayContentY, 150, 26) pullsDown:NO];
    [_headerSizePopup addItemWithTitle:@"Compact"];
    [_headerSizePopup addItemWithTitle:@"Normal"];
    [_headerSizePopup addItemWithTitle:@"Large"];
    _headerSizePopup.target = self;
    _headerSizePopup.action = @selector(headerSizeChanged:);
    [displayContent addSubview:_headerSizePopup];
    displayContentY += rowHeight + 4;

    // Header Accent
    NSTextField *headerAccentLabel = [NSTextField labelWithString:@"Header Accent:"];
    headerAccentLabel.frame = NSMakeRect(boxMargin, displayContentY + 3, labelWidth, 20);
    [displayContent addSubview:headerAccentLabel];

    _headerAccentPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(boxMargin + labelWidth, displayContentY, 150, 26) pullsDown:NO];
    [_headerAccentPopup addItemWithTitle:@"None"];
    [_headerAccentPopup addItemWithTitle:@"Tinted"];
    _headerAccentPopup.target = self;
    _headerAccentPopup.action = @selector(headerAccentChanged:);
    [displayContent addSubview:_headerAccentPopup];
    displayContentY += rowHeight + 4;

    // Group Header Spacing
    NSTextField *groupHeaderSpacingLabel = [NSTextField labelWithString:@"Group Header Spacing:"];
    groupHeaderSpacingLabel.frame = NSMakeRect(boxMargin, displayContentY + 3, labelWidth, 20);
    [displayContent addSubview:groupHeaderSpacingLabel];

    _groupHeaderSpacingPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(boxMargin + labelWidth, displayContentY, 150, 26) pullsDown:NO];
    [_groupHeaderSpacingPopup addItemWithTitle:@"Compact"];
    [_groupHeaderSpacingPopup addItemWithTitle:@"Normal"];
    [_groupHeaderSpacingPopup addItemWithTitle:@"Larger"];
    _groupHeaderSpacingPopup.target = self;
    _groupHeaderSpacingPopup.action = @selector(groupHeaderSpacingChanged:);
    [displayContent addSubview:_groupHeaderSpacingPopup];
    displayContentY += rowHeight + 4;

    // Glass Background
    _glassBackgroundCheckbox = [NSButton checkboxWithTitle:@"Glass background"
                                                    target:self
                                                    action:@selector(glassBackgroundChanged:)];
    _glassBackgroundCheckbox.frame = NSMakeRect(boxMargin + labelWidth, displayContentY, 280, 20);
    [displayContent addSubview:_glassBackgroundCheckbox];
    displayContentY += rowHeight;

    // Debug Rendering
    _debugRenderingCheckbox = [NSButton checkboxWithTitle:@"Show debug rendering diagnostics"
                                                   target:self
                                                   action:@selector(debugRenderingChanged:)];
    _debugRenderingCheckbox.frame = NSMakeRect(boxMargin + labelWidth, displayContentY, 280, 20);
    [displayContent addSubview:_debugRenderingCheckbox];
    displayContentY += rowHeight + 8;

    // Drag to Finder: move by default
    _dragToFinderMoveCheckbox = [NSButton checkboxWithTitle:@"Drag to Finder moves files (hold OPT to copy)"
                                                     target:self
                                                     action:@selector(dragToFinderMoveChanged:)];
    _dragToFinderMoveCheckbox.frame = NSMakeRect(boxMargin + labelWidth, displayContentY, 300, 20);
    [displayContent addSubview:_dragToFinderMoveCheckbox];
    displayContentY += 18;

    NSTextField *dragWarning = [NSTextField labelWithString:@"Warning: moves files from their original location when dragging out of foobar2000"];
    dragWarning.frame = NSMakeRect(boxMargin + labelWidth, displayContentY, 300, 28);
    dragWarning.font = [NSFont systemFontOfSize:10];
    dragWarning.textColor = [NSColor secondaryLabelColor];
    dragWarning.lineBreakMode = NSLineBreakByWordWrapping;
    [displayContent addSubview:dragWarning];

    y = displayBoxY + 455;

    // ==================== BEHAVIOR SETTINGS ====================
    CGFloat behaviorBoxY = y;
    CGFloat behaviorContentY = 22;

    NSBox *behaviorBox = [[NSBox alloc] initWithFrame:NSMakeRect(leftMargin, behaviorBoxY, 460, 180)];
    behaviorBox.title = @"Behavior";
    behaviorBox.titlePosition = NSAtTop;
    [container addSubview:behaviorBox];

    NSView *behaviorContent = [[SimPlaylistFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 440, 150)];
    behaviorBox.contentView = behaviorContent;

    // Double-click preserves queue
    _preserveQueueCheckbox = [NSButton checkboxWithTitle:@"Double-click preserves playback queue"
                                                  target:self
                                                  action:@selector(preserveQueueChanged:)];
    _preserveQueueCheckbox.frame = NSMakeRect(boxMargin + labelWidth, behaviorContentY, 300, 20);
    [behaviorContent addSubview:_preserveQueueCheckbox];
    behaviorContentY += rowHeight + 4;

    // Queue column display style
    NSTextField *queueStyleLabel = [NSTextField labelWithString:@"Queue Column:"];
    queueStyleLabel.frame = NSMakeRect(boxMargin, behaviorContentY + 3, labelWidth, 20);
    [behaviorContent addSubview:queueStyleLabel];

    _queueDisplayStylePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(boxMargin + labelWidth, behaviorContentY, 150, 26) pullsDown:NO];
    [_queueDisplayStylePopup addItemWithTitle:@"Brackets [1]"];
    [_queueDisplayStylePopup addItemWithTitle:@"Accent color"];
    _queueDisplayStylePopup.target = self;
    _queueDisplayStylePopup.action = @selector(queueDisplayStyleChanged:);
    [behaviorContent addSubview:_queueDisplayStylePopup];
    behaviorContentY += rowHeight + 4;

    // Finder-open behavior
    NSTextField *finderBehaviorLabel = [NSTextField labelWithString:@"Open from Finder:"];
    finderBehaviorLabel.frame = NSMakeRect(boxMargin, behaviorContentY + 3, labelWidth, 20);
    [behaviorContent addSubview:finderBehaviorLabel];

    _finderOpenBehaviorPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(boxMargin + labelWidth, behaviorContentY, 220, 26) pullsDown:NO];
    [_finderOpenBehaviorPopup addItemWithTitle:@"Replace active playlist (default)"];
    [_finderOpenBehaviorPopup addItemWithTitle:@"Append to active playlist"];
    [_finderOpenBehaviorPopup addItemWithTitle:@"Send to named playlist"];
    _finderOpenBehaviorPopup.target = self;
    _finderOpenBehaviorPopup.action = @selector(finderOpenBehaviorChanged:);
    [behaviorContent addSubview:_finderOpenBehaviorPopup];
    behaviorContentY += rowHeight + 4;

    // Target playlist picker is currently disabled — see BACKLOG.md.
    // "Send to named playlist" mode still works with the default playlist name
    // (saved in kFinderOpenTargetPlaylist, default "Inbox"). Re-enable this
    // section once the unresponsive-popup issue is resolved.
    //
    // NSTextField *finderTargetLabel = [NSTextField labelWithString:@"Target playlist:"];
    // finderTargetLabel.frame = NSMakeRect(boxMargin, behaviorContentY + 3, labelWidth, 20);
    // [behaviorContent addSubview:finderTargetLabel];
    // _finderOpenTargetPopupFrame = NSMakeRect(boxMargin + labelWidth, behaviorContentY, 220, 26);
    // _finderOpenTargetPopupParent = behaviorContent;

    y = behaviorBoxY + 200;

    // Help text — placed under the Pattern Help box on the right side
    CGFloat helpTextX = leftMargin + 460 + 20;
    CGFloat helpTextY = groupingBoxY + 215 + 8;  // below Pattern Help box
    NSTextField *helpText = [[NSTextField alloc] initWithFrame:NSMakeRect(helpTextX, helpTextY, 320, 180)];
    helpText.stringValue =
        @"Title format patterns (note spaces in field names):\n"
        @"  %artist%, %album artist%, %album%, %title%,\n"
        @"  %tracknumber%, %date%, %length%, %discnumber%\n"
        @"\n"
        @"[ ... ] = conditional, hides if all fields inside are empty\n"
        @"  e.g. [%album artist% - ][%album%] gives:\n"
        @"     \"Beatles - Abbey Road\" with album artist\n"
        @"     \"Abbey Road\" without album artist\n"
        @"\n"
        @"$if2(%a%,%b%) = use %a%, fall back to %b% if empty\n"
        @"  e.g. $if2(%album artist%,%artist%)";
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

    // Load show group duration
    bool showGroupDuration = simplaylist_config::getConfigBool(
        simplaylist_config::kShowGroupDuration,
        simplaylist_config::kDefaultShowGroupDuration);
    _showGroupDurationCheckbox.state = showGroupDuration ? NSControlStateValueOn : NSControlStateValueOff;

    // Load display size (0=compact, 1=normal, 2=large)
    int64_t displaySize = simplaylist_config::getConfigInt(
        simplaylist_config::kDisplaySize,
        simplaylist_config::kDefaultDisplaySize);
    [_displaySizePopup selectItemAtIndex:displaySize];

    // Load header size (0=compact, 1=normal, 2=large)
    int64_t headerSize = simplaylist_config::getConfigInt(
        simplaylist_config::kColumnHeaderSize,
        simplaylist_config::kDefaultColumnHeaderSize);
    [_headerSizePopup selectItemAtIndex:headerSize];

    // Load header accent (0=none, 1=tinted)
    int64_t headerAccent = simplaylist_config::getConfigInt(
        simplaylist_config::kHeaderAccentColor,
        simplaylist_config::kDefaultHeaderAccentColor);
    [_headerAccentPopup selectItemAtIndex:headerAccent];

    // Load group header spacing (0=normal, 1=larger)
    int64_t groupHeaderSpacing = simplaylist_config::getConfigInt(
        simplaylist_config::kGroupHeaderSpacing,
        simplaylist_config::kDefaultGroupHeaderSpacing);
    [_groupHeaderSpacingPopup selectItemAtIndex:groupHeaderSpacing];

    // Load glass background
    bool glassBackground = simplaylist_config::getConfigBool(
        simplaylist_config::kGlassBackground,
        simplaylist_config::kDefaultGlassBackground);
    _glassBackgroundCheckbox.state = glassBackground ? NSControlStateValueOn : NSControlStateValueOff;

    // Load debug rendering
    bool debugRendering = simplaylist_config::getConfigBool(
        simplaylist_config::kDebugRendering,
        simplaylist_config::kDefaultDebugRendering);
    _debugRenderingCheckbox.state = debugRendering ? NSControlStateValueOn : NSControlStateValueOff;

    // Load drag to Finder move
    bool dragToFinderMove = simplaylist_config::getConfigBool(
        simplaylist_config::kDragToFinderMove,
        simplaylist_config::kDefaultDragToFinderMove);
    _dragToFinderMoveCheckbox.state = dragToFinderMove ? NSControlStateValueOn : NSControlStateValueOff;

    // Load behavior settings
    bool preserveQueue = simplaylist_config::getConfigBool(
        simplaylist_config::kDoubleClickPreservesQueue,
        simplaylist_config::kDefaultDoubleClickPreservesQueue);
    _preserveQueueCheckbox.state = preserveQueue ? NSControlStateValueOn : NSControlStateValueOff;

    int64_t queueStyle = simplaylist_config::getConfigInt(
        simplaylist_config::kQueueDisplayStyle,
        simplaylist_config::kDefaultQueueDisplayStyle);
    [_queueDisplayStylePopup selectItemAtIndex:queueStyle];

    // Load Finder-open behavior
    int64_t finderBehavior = simplaylist_config::getConfigInt(
        simplaylist_config::kFinderOpenBehavior,
        simplaylist_config::kDefaultFinderOpenBehavior);
    if (finderBehavior < 0 || finderBehavior > 2) finderBehavior = 0;
    [_finderOpenBehaviorPopup selectItemAtIndex:finderBehavior];

    // Target playlist picker is currently disabled — see BACKLOG.md.
    // The config value is still respected by the override; just no UI to edit it.
    // std::string finderTarget = simplaylist_config::getConfigString(
    //     simplaylist_config::kFinderOpenTargetPlaylist,
    //     simplaylist_config::kDefaultFinderOpenTargetPlaylist);
    // [self rebuildPlaylistTargetPopupSelecting:[NSString stringWithUTF8String:finderTarget.c_str()]];

    // Validate the loaded pattern fields once so warnings show for any saved typos.
    [self refreshPatternWarnings];
}

// Build the Target playlist popup fresh from scratch. Avoids removeAllItems
// pitfalls by always constructing a new NSPopUpButton with items inline.
- (void)rebuildPlaylistTargetPopupSelecting:(NSString *)selectedName {
    if (_finderOpenTargetPopup) {
        [_finderOpenTargetPopup removeFromSuperview];
        _finderOpenTargetPopup = nil;
    }
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:_finderOpenTargetPopupFrame pullsDown:NO];
    popup.target = self;
    popup.action = @selector(finderOpenTargetChanged:);

    auto pm = playlist_manager::get();
    t_size count = pm->get_playlist_count();
    pfc::string8 name;
    BOOL foundSelected = NO;
    for (t_size i = 0; i < count; i++) {
        if (pm->playlist_get_name(i, name)) {
            NSString *s = [NSString stringWithUTF8String:name.c_str()];
            if (s.length == 0) continue;
            [popup addItemWithTitle:s];
            if ([s isEqualToString:selectedName]) foundSelected = YES;
        }
    }
    // If saved name isn't an existing playlist, prepend so it's still selectable
    // (it'll be created on demand when the override fires).
    if (!foundSelected && selectedName.length > 0) {
        [popup insertItemWithTitle:selectedName atIndex:0];
    }
    [popup selectItemWithTitle:selectedName];

    [_finderOpenTargetPopupParent addSubview:popup];
    _finderOpenTargetPopup = popup;
}

- (void)updateFieldsForPreset:(GroupPreset *)preset {
    _headerPatternField.stringValue = preset.headerPattern ?: @"";
    _subgroupPatternField.stringValue = preset.subgroupPattern ?: @"";
    [self refreshPatternWarnings];
}

// Scan a title-format pattern for common typos that produce empty output.
// Returns a warning string for display, or nil if no issues found.
// We deliberately only flag KNOWN typos (not "unknown" fields), since custom
// tags are valid in foobar2000 and we don't want false positives.
+ (NSString *)warningForPattern:(NSString *)pattern {
    if (pattern.length == 0) return nil;
    NSString *lower = pattern.lowercaseString;

    // typo → correction (in lowercase; we match case-insensitive)
    static NSDictionary<NSString *, NSString *> *typos = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        typos = @{
            @"%albumartist%":   @"%album artist%",
            @"%album_artist%":  @"%album artist%",
            @"%albumartists%":  @"%album artist%",
            @"%trackno%":       @"%tracknumber%",
            @"%track_number%":  @"%tracknumber%",
            @"%trackno.%":      @"%tracknumber%",
            @"%discno%":        @"%discnumber%",
            @"%disc_number%":   @"%discnumber%",
            @"%discno.%":       @"%discnumber%",
            @"%year%":          @"%date%",
            @"%total_tracks%":  @"%totaltracks%",
            @"%total_discs%":   @"%totaldiscs%",
        };
    });

    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (NSString *typo in typos) {
        if ([lower rangeOfString:typo].location != NSNotFound) {
            [hits addObject:[NSString stringWithFormat:@"%@ → %@", typo, typos[typo]]];
        }
    }
    if (hits.count == 0) return nil;
    return [NSString stringWithFormat:@"⚠ Unknown field — did you mean: %@",
            [hits componentsJoinedByString:@", "]];
}

// Resolve a pattern against a representative track from the active playlist —
// prefers selected/focused item, falls back to first. This matches what the
// user is likely looking at in the SimPlaylist panel.
+ (NSString *)previewForPattern:(NSString *)pattern {
    if (pattern.length == 0) return @"";
    auto pm = playlist_manager::get();
    t_size active = pm->get_active_playlist();
    if (active == SIZE_MAX) return @"(no active playlist)";
    t_size itemCount = pm->playlist_get_item_count(active);
    if (itemCount == 0) return @"(active playlist is empty)";

    // Prefer focused item (what user last clicked/arrow-keyed to in SimPlaylist),
    // fall back to first item.
    metadb_handle_ptr handle;
    if (!pm->playlist_get_focus_item_handle(handle, active) || handle.is_empty()) {
        handle = pm->playlist_get_item_handle(active, 0);
    }
    if (handle.is_empty()) return @"(no track to preview)";

    auto script = simplaylist::TitleFormatHelper::compile([pattern UTF8String]);
    if (script.is_empty()) return @"(invalid pattern)";

    std::string result = simplaylist::TitleFormatHelper::format(handle, script);
    NSString *str = [NSString stringWithUTF8String:result.c_str()];
    NSString *trimmed = [str stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return @"(empty — fields may be missing on this track)";
    return str;
}

- (void)refreshPatternWarnings {
    NSString *headerWarn = [SimPlaylistPreferencesController warningForPattern:_headerPatternField.stringValue];
    _headerPatternWarning.stringValue = headerWarn ?: @"";
    _headerPatternWarning.hidden = (headerWarn == nil);
    _headerPatternPreview.stringValue =
        [SimPlaylistPreferencesController previewForPattern:_headerPatternField.stringValue];

    NSString *subWarn = [SimPlaylistPreferencesController warningForPattern:_subgroupPatternField.stringValue];
    _subgroupPatternWarning.stringValue = subWarn ?: @"";
    _subgroupPatternWarning.hidden = (subWarn == nil);
    _subgroupPatternPreview.stringValue =
        [SimPlaylistPreferencesController previewForPattern:_subgroupPatternField.stringValue];
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
    // Live warnings update immediately so the user gets feedback as they type
    if (notification.object == _headerPatternField || notification.object == _subgroupPatternField) {
        [self refreshPatternWarnings];
    }
    // Debounce save/notify to avoid rebuilding on every keystroke
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

- (void)showGroupDurationChanged:(id)sender {
    bool enabled = (_showGroupDurationCheckbox.state == NSControlStateValueOn);
    simplaylist_config::setConfigBool(simplaylist_config::kShowGroupDuration, enabled);

    // Controller's redraw handler will re-read the flag and recompute durations
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

- (void)headerSizeChanged:(id)sender {
    NSInteger size = _headerSizePopup.indexOfSelectedItem;
    simplaylist_config::setConfigInt(simplaylist_config::kColumnHeaderSize, size);

    // Needs full rebuild because header height changes
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistSettingsChanged"
                                                        object:nil];
}

- (void)headerAccentChanged:(id)sender {
    NSInteger accent = _headerAccentPopup.indexOfSelectedItem;
    simplaylist_config::setConfigInt(simplaylist_config::kHeaderAccentColor, accent);

    // Needs redraw for header color change
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistSettingsChanged"
                                                        object:nil];
}

- (void)groupHeaderSpacingChanged:(id)sender {
    NSInteger spacing = _groupHeaderSpacingPopup.indexOfSelectedItem;
    simplaylist_config::setConfigInt(simplaylist_config::kGroupHeaderSpacing, spacing);

    // Needs settings reload for spacing change
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistSettingsChanged"
                                                        object:nil];
}

- (void)glassBackgroundChanged:(id)sender {
    bool enabled = (_glassBackgroundCheckbox.state == NSControlStateValueOn);
    simplaylist_config::setConfigBool(simplaylist_config::kGlassBackground, enabled);

    // Needs full rebuild - container view type changes
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistSettingsChanged"
                                                        object:nil];
}

- (void)debugRenderingChanged:(id)sender {
    bool enabled = (_debugRenderingCheckbox.state == NSControlStateValueOn);
    simplaylist_config::setConfigBool(simplaylist_config::kDebugRendering, enabled);

    // Only needs redraw, not full rebuild
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistRedrawNeeded"
                                                        object:nil];
}

- (void)dragToFinderMoveChanged:(id)sender {
    bool enabled = (_dragToFinderMoveCheckbox.state == NSControlStateValueOn);
    simplaylist_config::setConfigBool(simplaylist_config::kDragToFinderMove, enabled);
}

- (void)preserveQueueChanged:(id)sender {
    bool enabled = (_preserveQueueCheckbox.state == NSControlStateValueOn);
    simplaylist_config::setConfigBool(simplaylist_config::kDoubleClickPreservesQueue, enabled);
}

- (void)queueDisplayStyleChanged:(id)sender {
    int64_t style = [_queueDisplayStylePopup indexOfSelectedItem];
    simplaylist_config::setConfigInt(simplaylist_config::kQueueDisplayStyle, style);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistRedrawNeeded" object:nil];
}

- (void)finderOpenBehaviorChanged:(id)sender {
    int64_t behavior = [_finderOpenBehaviorPopup indexOfSelectedItem];
    simplaylist_config::setConfigInt(simplaylist_config::kFinderOpenBehavior, behavior);
}

- (void)finderOpenTargetChanged:(id)sender {
    NSString *value = _finderOpenTargetPopup.titleOfSelectedItem ?: @"";
    simplaylist_config::setConfigString(simplaylist_config::kFinderOpenTargetPlaylist,
                                        [value UTF8String]);
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
