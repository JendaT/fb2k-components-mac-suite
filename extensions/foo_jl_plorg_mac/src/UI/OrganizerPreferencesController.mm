//
//  OrganizerPreferencesController.mm
//  foo_plorg_mac
//

#import "OrganizerPreferencesController.h"
#import "../Core/TreeModel.h"
#import "../Core/ConfigHelper.h"
#import "../../../../shared/PreferencesCommon.h"

@interface OrganizerPreferencesController ()
@property (nonatomic, strong) NSButton *singleClickActivateCheckbox;
@property (nonatomic, strong) NSButton *doubleClickPlayCheckbox;
@property (nonatomic, strong) NSButton *autoRevealPlayingCheckbox;
@property (nonatomic, strong) NSButton *showIconsCheckbox;
@property (nonatomic, strong) NSButton *showTreeLinesCheckbox;
@property (nonatomic, strong) NSButton *transparentBackgroundCheckbox;
@property (nonatomic, strong) NSButton *syncPlaylistsCheckbox;
@property (nonatomic, strong) NSTextField *nodeFormatField;
@end

@implementation OrganizerPreferencesController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    return self;
}

- (void)loadView {
    // IMPORTANT: macOS coordinate system has y=0 at BOTTOM, not top.
    // Using manual frame positioning with y counting down will align content to bottom.
    // Solution: Use Auto Layout with constraints pinned to TOP of container.

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];

    CGFloat leftMargin = 20;
    __block CGFloat currentY = 20;  // Start from top with padding
    CGFloat rowHeight = 22;
    CGFloat sectionGap = 12;

    // Helper to add a view and advance Y (top-down layout)
    void (^addRow)(NSView *, CGFloat) = ^(NSView *view, CGFloat height) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.topAnchor constraintEqualToAnchor:container.topAnchor constant:currentY],
            [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:leftMargin],
            [view.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-leftMargin],
        ]];
        currentY += height;
    };

    void (^addIndentedRow)(NSView *, CGFloat) = ^(NSView *view, CGFloat height) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.topAnchor constraintEqualToAnchor:container.topAnchor constant:currentY],
            [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:leftMargin + 10],
            [view.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-leftMargin],
        ]];
        currentY += height;
    };

    // Title (non-bold, matches foobar2000 style)
    NSTextField *title = JLCreatePreferencesTitle(@"Playlist Organizer Settings");
    addRow(title, 28);

    // Behavior section
    NSTextField *behaviorLabel = [NSTextField labelWithString:@"Behavior:"];
    behaviorLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    behaviorLabel.textColor = [NSColor secondaryLabelColor];
    addRow(behaviorLabel, rowHeight);

    // Single click activate
    self.singleClickActivateCheckbox = [NSButton checkboxWithTitle:@"Activate playlist on single click"
                                                            target:self
                                                            action:@selector(settingsChanged:)];
    addIndentedRow(self.singleClickActivateCheckbox, rowHeight);

    // Double click play
    self.doubleClickPlayCheckbox = [NSButton checkboxWithTitle:@"Play next track on double-click"
                                                        target:self
                                                        action:@selector(settingsChanged:)];
    addIndentedRow(self.doubleClickPlayCheckbox, rowHeight);

    // Auto reveal playing
    self.autoRevealPlayingCheckbox = [NSButton checkboxWithTitle:@"Auto-reveal currently playing playlist"
                                                          target:self
                                                          action:@selector(settingsChanged:)];
    addIndentedRow(self.autoRevealPlayingCheckbox, rowHeight);

    // Sync playlists
    self.syncPlaylistsCheckbox = [NSButton checkboxWithTitle:@"Sync with foobar2000 playlists"
                                                      target:self
                                                      action:@selector(settingsChanged:)];
    addIndentedRow(self.syncPlaylistsCheckbox, rowHeight + sectionGap);

    // Appearance section
    NSTextField *appearanceLabel = [NSTextField labelWithString:@"Appearance:"];
    appearanceLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    appearanceLabel.textColor = [NSColor secondaryLabelColor];
    addRow(appearanceLabel, rowHeight);

    // Show icons
    self.showIconsCheckbox = [NSButton checkboxWithTitle:@"Show folder/playlist icons"
                                                  target:self
                                                  action:@selector(settingsChanged:)];
    addIndentedRow(self.showIconsCheckbox, rowHeight);

    // Show tree lines
    self.showTreeLinesCheckbox = [NSButton checkboxWithTitle:@"Show tree connection lines (best for 1 nesting level)"
                                                      target:self
                                                      action:@selector(settingsChanged:)];
    addIndentedRow(self.showTreeLinesCheckbox, rowHeight);

    // Transparent background
    self.transparentBackgroundCheckbox = [NSButton checkboxWithTitle:@"Transparent background (glass effect) - requires restart"
                                                              target:self
                                                              action:@selector(settingsChanged:)];
    addIndentedRow(self.transparentBackgroundCheckbox, rowHeight + 8);

    // Node format label
    NSTextField *formatLabel = [NSTextField labelWithString:@"Node format:"];
    addIndentedRow(formatLabel, rowHeight);

    // Node format field
    self.nodeFormatField = [[NSTextField alloc] init];
    self.nodeFormatField.placeholderString = @"%node_name%";
    self.nodeFormatField.target = self;
    self.nodeFormatField.action = @selector(settingsChanged:);
    self.nodeFormatField.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.nodeFormatField];
    [NSLayoutConstraint activateConstraints:@[
        [self.nodeFormatField.topAnchor constraintEqualToAnchor:container.topAnchor constant:currentY],
        [self.nodeFormatField.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:leftMargin + 10],
        [self.nodeFormatField.widthAnchor constraintEqualToConstant:340],
    ]];
    currentY += 26;

    // Format hint
    NSTextField *formatHint = [NSTextField labelWithString:@"Variables: %node_name%, %is_folder%, %count%"];
    formatHint.font = [NSFont systemFontOfSize:10];
    formatHint.textColor = [NSColor tertiaryLabelColor];
    addIndentedRow(formatHint, rowHeight + sectionGap);

    // Reset button
    NSButton *resetButton = [NSButton buttonWithTitle:@"Reset to Defaults"
                                               target:self
                                               action:@selector(resetToDefaults:)];
    addIndentedRow(resetButton, 30);

    self.view = container;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadSettings];
}

- (void)loadSettings {
    // Load settings from config
    BOOL singleClick = plorg_config::getConfigBool(plorg_config::kSingleClickActivate, false);
    BOOL doubleClickPlay = plorg_config::getConfigBool(plorg_config::kDoubleClickPlay, true);
    BOOL autoReveal = plorg_config::getConfigBool(plorg_config::kAutoRevealPlaying, true);
    BOOL showIcons = plorg_config::getConfigBool(plorg_config::kShowIcons, true);
    BOOL showTreeLines = plorg_config::getConfigBool(plorg_config::kShowTreeLines, plorg_config::kDefaultShowTreeLines);
    BOOL transparentBackground = plorg_config::getConfigBool(plorg_config::kTransparentBackground, plorg_config::kDefaultTransparentBackground);
    BOOL syncPlaylists = plorg_config::getConfigBool(plorg_config::kSyncPlaylists, plorg_config::kDefaultSyncPlaylists);
    NSString *format = plorg_config::getConfigString(plorg_config::kNodeFormat, "%node_name%");

    self.singleClickActivateCheckbox.state = singleClick ? NSControlStateValueOn : NSControlStateValueOff;
    self.doubleClickPlayCheckbox.state = doubleClickPlay ? NSControlStateValueOn : NSControlStateValueOff;
    self.autoRevealPlayingCheckbox.state = autoReveal ? NSControlStateValueOn : NSControlStateValueOff;
    self.showIconsCheckbox.state = showIcons ? NSControlStateValueOn : NSControlStateValueOff;
    self.showTreeLinesCheckbox.state = showTreeLines ? NSControlStateValueOn : NSControlStateValueOff;
    self.transparentBackgroundCheckbox.state = transparentBackground ? NSControlStateValueOn : NSControlStateValueOff;
    self.syncPlaylistsCheckbox.state = syncPlaylists ? NSControlStateValueOn : NSControlStateValueOff;
    self.nodeFormatField.stringValue = format ?: @"%node_name%";
}

- (void)saveSettings {
    plorg_config::setConfigBool(plorg_config::kSingleClickActivate,
                                self.singleClickActivateCheckbox.state == NSControlStateValueOn);
    plorg_config::setConfigBool(plorg_config::kDoubleClickPlay,
                                self.doubleClickPlayCheckbox.state == NSControlStateValueOn);
    plorg_config::setConfigBool(plorg_config::kAutoRevealPlaying,
                                self.autoRevealPlayingCheckbox.state == NSControlStateValueOn);
    plorg_config::setConfigBool(plorg_config::kShowIcons,
                                self.showIconsCheckbox.state == NSControlStateValueOn);
    plorg_config::setConfigBool(plorg_config::kShowTreeLines,
                                self.showTreeLinesCheckbox.state == NSControlStateValueOn);
    plorg_config::setConfigBool(plorg_config::kTransparentBackground,
                                self.transparentBackgroundCheckbox.state == NSControlStateValueOn);
    plorg_config::setConfigBool(plorg_config::kSyncPlaylists,
                                self.syncPlaylistsCheckbox.state == NSControlStateValueOn);

    NSString *format = self.nodeFormatField.stringValue;
    if (format.length > 0) {
        plorg_config::setConfigString(plorg_config::kNodeFormat, format);
        [TreeModel shared].nodeFormat = format;
    }

    // Notify that settings changed
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PlorgSettingsChanged" object:nil];
}

- (void)settingsChanged:(id)sender {
    [self saveSettings];
}

- (void)resetToDefaults:(id)sender {
    self.singleClickActivateCheckbox.state = NSControlStateValueOff;
    self.doubleClickPlayCheckbox.state = NSControlStateValueOn;
    self.autoRevealPlayingCheckbox.state = NSControlStateValueOn;
    self.showIconsCheckbox.state = NSControlStateValueOn;
    self.showTreeLinesCheckbox.state = NSControlStateValueOn;
    self.transparentBackgroundCheckbox.state = NSControlStateValueOn;
    self.syncPlaylistsCheckbox.state = NSControlStateValueOn;
    self.nodeFormatField.stringValue = @"%node_name%";
    [self saveSettings];
}

@end
