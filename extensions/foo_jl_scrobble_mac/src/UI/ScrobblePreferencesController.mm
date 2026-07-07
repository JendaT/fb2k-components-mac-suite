//
//  ScrobblePreferencesController.mm
//  foo_scrobble_mac
//
//  Preferences page implementation
//

#import "ScrobblePreferencesController.h"
#import "../Core/ScrobbleConfig.h"
#import "../Core/ScrobbleNotifications.h"
#import "../Core/ScrobbleTrack.h"
#import "../LastFm/LastFmAuth.h"
#import "../Services/ScrobbleService.h"
#import "../Services/ScrobbleCache.h"
#import "ScrobbleColorUtils.h"
#import "../../../../shared/PreferencesCommon.h"

@class ScrobbleTrack;

@interface ScrobblePreferencesController () <NSTableViewDataSource, NSTableViewDelegate>
// Authentication UI
@property (nonatomic, strong) NSImageView *profileImageView;
@property (nonatomic, strong) NSTextField *authStatusLabel;
@property (nonatomic, strong) NSTextField *usernameLabel;
@property (nonatomic, strong) NSButton *authButton;
@property (nonatomic, strong) NSProgressIndicator *authSpinner;

// Settings checkboxes
@property (nonatomic, strong) NSButton *enableScrobblingCheckbox;
@property (nonatomic, strong) NSButton *enableNowPlayingCheckbox;
@property (nonatomic, strong) NSButton *libraryOnlyCheckbox;
@property (nonatomic, strong) NSButton *dynamicSourcesCheckbox;

// Widget settings
@property (nonatomic, strong) NSPopUpButton *cacheDurationPopup;
@property (nonatomic, strong) NSPopUpButton *displayStylePopup;
@property (nonatomic, strong) NSButton *streakDisplayCheckbox;
@property (nonatomic, strong) NSButton *glassBackgroundCheckbox;
@property (nonatomic, strong) NSColorWell *backgroundColorWell;

// Status labels
@property (nonatomic, strong) NSTextField *queueStatusLabel;
@property (nonatomic, strong) NSTextField *sessionStatsLabel;

// Cache table
@property (nonatomic, strong) NSTableView *cacheTableView;
@property (nonatomic, strong) NSScrollView *cacheScrollView;
@property (nonatomic, strong) NSButton *deleteButton;
@property (nonatomic, strong) NSArray<ScrobbleTrack*> *cachedTracks;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@end

@implementation ScrobblePreferencesController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        // Observe auth state changes
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(authStateChanged:)
                                                     name:LastFmAuthStateDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(cacheChanged:)
                                                     name:ScrobbleCacheDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(serviceStateChanged:)
                                                     name:ScrobbleServiceStateDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 450, 350)];

    CGFloat leftMargin = 20;
    __block CGFloat currentY = 20;
    CGFloat rowHeight = 24;
    CGFloat sectionGap = 16;

    // Helper to add a view with Auto Layout
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
            [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:leftMargin + 16],
            [view.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-leftMargin],
        ]];
        currentY += height;
    };

    // ===== Title (non-bold, matches foobar2000 style) =====
    NSTextField *title = JLCreatePreferencesTitle(@"Last.fm Scrobbler");
    addRow(title, 30);

    // ===== Account Section =====
    NSTextField *accountLabel = [NSTextField labelWithString:@"Account"];
    accountLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    accountLabel.textColor = [NSColor secondaryLabelColor];
    addRow(accountLabel, rowHeight);

    // Profile image and auth status row
    NSStackView *profileRow = [[NSStackView alloc] init];
    profileRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    profileRow.spacing = 12;
    profileRow.alignment = NSLayoutAttributeCenterY;

    // Profile image (rounded, 48x48)
    self.profileImageView = [[NSImageView alloc] init];
    self.profileImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.profileImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.profileImageView.wantsLayer = YES;
    self.profileImageView.layer.cornerRadius = 24;
    self.profileImageView.layer.masksToBounds = YES;
    self.profileImageView.layer.borderWidth = 1;
    self.profileImageView.layer.borderColor = [[NSColor separatorColor] CGColor];
    [NSLayoutConstraint activateConstraints:@[
        [self.profileImageView.widthAnchor constraintEqualToConstant:48],
        [self.profileImageView.heightAnchor constraintEqualToConstant:48]
    ]];
    // Default placeholder icon
    if (@available(macOS 11.0, *)) {
        self.profileImageView.image = [NSImage imageWithSystemSymbolName:@"person.circle.fill"
                                                accessibilityDescription:@"Profile"];
        self.profileImageView.contentTintColor = [NSColor tertiaryLabelColor];
    }
    [profileRow addArrangedSubview:self.profileImageView];

    // Vertical stack for username and status
    NSStackView *infoStack = [[NSStackView alloc] init];
    infoStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    infoStack.spacing = 2;
    infoStack.alignment = NSLayoutAttributeLeading;

    self.usernameLabel = [NSTextField labelWithString:@""];
    self.usernameLabel.font = [NSFont boldSystemFontOfSize:13];
    self.usernameLabel.textColor = [NSColor labelColor];
    [infoStack addArrangedSubview:self.usernameLabel];

    self.authStatusLabel = [NSTextField labelWithString:@"Not signed in"];
    self.authStatusLabel.font = [NSFont systemFontOfSize:11];
    self.authStatusLabel.textColor = [NSColor secondaryLabelColor];
    [infoStack addArrangedSubview:self.authStatusLabel];

    [profileRow addArrangedSubview:infoStack];

    self.authSpinner = [[NSProgressIndicator alloc] init];
    self.authSpinner.style = NSProgressIndicatorStyleSpinning;
    self.authSpinner.controlSize = NSControlSizeSmall;
    [self.authSpinner setHidden:YES];
    [profileRow addArrangedSubview:self.authSpinner];

    addIndentedRow(profileRow, 56);

    // Auth button
    self.authButton = [NSButton buttonWithTitle:@"Sign In with Last.fm"
                                         target:self
                                         action:@selector(authButtonClicked:)];
    addIndentedRow(self.authButton, 32 + sectionGap);

    // ===== Scrobbling Options =====
    NSTextField *optionsLabel = [NSTextField labelWithString:@"Scrobbling Options"];
    optionsLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    optionsLabel.textColor = [NSColor secondaryLabelColor];
    addRow(optionsLabel, rowHeight);

    self.enableScrobblingCheckbox = [NSButton checkboxWithTitle:@"Enable scrobbling"
                                                         target:self
                                                         action:@selector(settingsChanged:)];
    addIndentedRow(self.enableScrobblingCheckbox, rowHeight);

    self.enableNowPlayingCheckbox = [NSButton checkboxWithTitle:@"Send Now Playing notifications"
                                                         target:self
                                                         action:@selector(settingsChanged:)];
    addIndentedRow(self.enableNowPlayingCheckbox, rowHeight);

    self.libraryOnlyCheckbox = [NSButton checkboxWithTitle:@"Only scrobble tracks in Media Library"
                                                    target:self
                                                    action:@selector(settingsChanged:)];
    addIndentedRow(self.libraryOnlyCheckbox, rowHeight);

    self.dynamicSourcesCheckbox = [NSButton checkboxWithTitle:@"Scrobble from dynamic sources (radio, etc.)"
                                                       target:self
                                                       action:@selector(settingsChanged:)];
    addIndentedRow(self.dynamicSourcesCheckbox, rowHeight + sectionGap);

    // ===== Widget Settings =====
    NSTextField *widgetLabel = [NSTextField labelWithString:@"Widget Settings"];
    widgetLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    widgetLabel.textColor = [NSColor secondaryLabelColor];
    addRow(widgetLabel, rowHeight);

    // Cache duration row with label and popup
    NSStackView *cacheRow = [[NSStackView alloc] init];
    cacheRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    cacheRow.spacing = 8;
    cacheRow.alignment = NSLayoutAttributeCenterY;

    NSTextField *cacheLabel = [NSTextField labelWithString:@"Cache chart data for:"];
    cacheLabel.font = [NSFont systemFontOfSize:11];
    cacheLabel.textColor = [NSColor labelColor];
    [cacheRow addArrangedSubview:cacheLabel];

    self.cacheDurationPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.cacheDurationPopup.font = [NSFont systemFontOfSize:11];
    [self.cacheDurationPopup addItemsWithTitles:@[
        @"No caching", @"1 minute", @"2 minutes", @"5 minutes", @"10 minutes", @"30 minutes",
        @"1 hour", @"4 hours", @"12 hours", @"1 day", @"2 days", @"7 days", @"30 days", @"180 days"
    ]];
    self.cacheDurationPopup.target = self;
    self.cacheDurationPopup.action = @selector(cacheDurationChanged:);
    [cacheRow addArrangedSubview:self.cacheDurationPopup];

    addIndentedRow(cacheRow, rowHeight);

    // Display style row
    NSStackView *displayStyleRow = [[NSStackView alloc] init];
    displayStyleRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    displayStyleRow.spacing = 8;
    displayStyleRow.alignment = NSLayoutAttributeCenterY;

    NSTextField *displayStyleLabel = [NSTextField labelWithString:@"Display style:"];
    displayStyleLabel.font = [NSFont systemFontOfSize:11];
    displayStyleLabel.textColor = [NSColor labelColor];
    [displayStyleRow addArrangedSubview:displayStyleLabel];

    self.displayStylePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.displayStylePopup.font = [NSFont systemFontOfSize:11];
    [self.displayStylePopup addItemsWithTitles:@[@"Default (Grid)", @"Playback 2025 (Bubbles)"]];
    self.displayStylePopup.target = self;
    self.displayStylePopup.action = @selector(displayStyleChanged:);
    [displayStyleRow addArrangedSubview:self.displayStylePopup];

    addIndentedRow(displayStyleRow, rowHeight);

    // Streak display checkbox
    self.streakDisplayCheckbox = [NSButton checkboxWithTitle:@"Show listening streak in footer"
                                                      target:self
                                                      action:@selector(streakDisplayChanged:)];
    addIndentedRow(self.streakDisplayCheckbox, rowHeight);

    // Glass background checkbox
    self.glassBackgroundCheckbox = [NSButton checkboxWithTitle:@"Use glass background effect"
                                                        target:self
                                                        action:@selector(glassBackgroundChanged:)];
    addIndentedRow(self.glassBackgroundCheckbox, rowHeight);

    // Background color row
    NSStackView *bgColorRow = [[NSStackView alloc] init];
    bgColorRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bgColorRow.spacing = 8;
    bgColorRow.alignment = NSLayoutAttributeCenterY;

    NSTextField *bgColorLabel = [NSTextField labelWithString:@"Background color:"];
    bgColorLabel.font = [NSFont systemFontOfSize:11];
    bgColorLabel.textColor = [NSColor labelColor];
    [bgColorRow addArrangedSubview:bgColorLabel];

    self.backgroundColorWell = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 40, 24)];
    self.backgroundColorWell.target = self;
    self.backgroundColorWell.action = @selector(backgroundColorChanged:);
    if (@available(macOS 13.0, *)) {
        self.backgroundColorWell.colorWellStyle = NSColorWellStyleMinimal;
    }
    [self.backgroundColorWell setTranslatesAutoresizingMaskIntoConstraints:NO];
    [NSLayoutConstraint activateConstraints:@[
        [self.backgroundColorWell.widthAnchor constraintEqualToConstant:40],
        [self.backgroundColorWell.heightAnchor constraintEqualToConstant:24]
    ]];
    [bgColorRow addArrangedSubview:self.backgroundColorWell];

    NSTextField *bgColorHint = [NSTextField labelWithString:@"(disabled when glass is on)"];
    bgColorHint.font = [NSFont systemFontOfSize:10];
    bgColorHint.textColor = [NSColor tertiaryLabelColor];
    [bgColorRow addArrangedSubview:bgColorHint];

    addIndentedRow(bgColorRow, rowHeight + sectionGap);

    // ===== Status Section =====
    NSTextField *statusLabel = [NSTextField labelWithString:@"Status"];
    statusLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    statusLabel.textColor = [NSColor secondaryLabelColor];
    addRow(statusLabel, rowHeight);

    self.queueStatusLabel = [NSTextField labelWithString:@"Queue: 0 pending"];
    self.queueStatusLabel.font = [NSFont systemFontOfSize:11];
    self.queueStatusLabel.textColor = [NSColor secondaryLabelColor];
    addIndentedRow(self.queueStatusLabel, rowHeight);

    self.sessionStatsLabel = [NSTextField labelWithString:@"Session: 0 scrobbled"];
    self.sessionStatsLabel.font = [NSFont systemFontOfSize:11];
    self.sessionStatsLabel.textColor = [NSColor secondaryLabelColor];
    addIndentedRow(self.sessionStatsLabel, rowHeight + sectionGap);

    // ===== Scrobble Queue Section =====
    NSTextField *queueLabel = [NSTextField labelWithString:@"Scrobble Queue"];
    queueLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    queueLabel.textColor = [NSColor secondaryLabelColor];
    addRow(queueLabel, rowHeight);

    // Date formatter for the table
    self.dateFormatter = [[NSDateFormatter alloc] init];
    self.dateFormatter.dateStyle = NSDateFormatterShortStyle;
    self.dateFormatter.timeStyle = NSDateFormatterShortStyle;

    // Table view inside scroll view
    self.cacheTableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.cacheTableView.dataSource = self;
    self.cacheTableView.delegate = self;
    self.cacheTableView.allowsMultipleSelection = YES;
    self.cacheTableView.usesAlternatingRowBackgroundColors = YES;
    self.cacheTableView.rowHeight = 18;
    self.cacheTableView.headerView.frame = NSMakeRect(0, 0, 0, 20);
    self.cacheTableView.style = NSTableViewStylePlain;
    self.cacheTableView.font = [NSFont systemFontOfSize:11];

    NSTableColumn *artistCol = [[NSTableColumn alloc] initWithIdentifier:@"artist"];
    artistCol.title = @"Artist";
    artistCol.width = 120;
    artistCol.minWidth = 60;
    [self.cacheTableView addTableColumn:artistCol];

    NSTableColumn *titleCol = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    titleCol.title = @"Title";
    titleCol.width = 120;
    titleCol.minWidth = 60;
    [self.cacheTableView addTableColumn:titleCol];

    NSTableColumn *albumCol = [[NSTableColumn alloc] initWithIdentifier:@"album"];
    albumCol.title = @"Album";
    albumCol.width = 100;
    albumCol.minWidth = 40;
    [self.cacheTableView addTableColumn:albumCol];

    NSTableColumn *dateCol = [[NSTableColumn alloc] initWithIdentifier:@"date"];
    dateCol.title = @"Date";
    dateCol.width = 110;
    dateCol.minWidth = 80;
    [self.cacheTableView addTableColumn:dateCol];

    self.cacheScrollView = [[NSScrollView alloc] init];
    self.cacheScrollView.documentView = self.cacheTableView;
    self.cacheScrollView.hasVerticalScroller = YES;
    self.cacheScrollView.autohidesScrollers = YES;
    self.cacheScrollView.borderType = NSBezelBorder;

    self.cacheScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.cacheScrollView];
    [NSLayoutConstraint activateConstraints:@[
        [self.cacheScrollView.topAnchor constraintEqualToAnchor:container.topAnchor constant:currentY],
        [self.cacheScrollView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:leftMargin + 16],
        [self.cacheScrollView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-leftMargin],
        [self.cacheScrollView.heightAnchor constraintEqualToConstant:140],
    ]];
    currentY += 148;

    // Delete button row
    self.deleteButton = [NSButton buttonWithTitle:@"Delete Selected"
                                            target:self
                                            action:@selector(deleteSelectedTracks:)];
    self.deleteButton.font = [NSFont systemFontOfSize:11];
    self.deleteButton.enabled = NO;
    addIndentedRow(self.deleteButton, 28 + sectionGap);

    // ===== Footer =====
    NSTextField *footerLabel = [NSTextField labelWithString:@"Scrobbles tracks after 50% or 4 minutes of playback."];
    footerLabel.font = [NSFont systemFontOfSize:10];
    footerLabel.textColor = [NSColor tertiaryLabelColor];
    addIndentedRow(footerLabel, rowHeight);

    self.view = container;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadSettings];
    [self updateAuthUI];
    [self updateStatusLabels];
    [self reloadCacheTable];
}

#pragma mark - Settings

- (void)loadSettings {
    self.enableScrobblingCheckbox.state = scrobble_config::isScrobblingEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    self.enableNowPlayingCheckbox.state = scrobble_config::isNowPlayingEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    self.libraryOnlyCheckbox.state = scrobble_config::isLibraryOnlyEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    self.dynamicSourcesCheckbox.state = scrobble_config::isDynamicSourcesEnabled() ? NSControlStateValueOn : NSControlStateValueOff;

    // Load cache duration setting
    int64_t cacheDuration = scrobble_config::getWidgetCacheDuration();
    NSInteger popupIndex = 3;  // Default to 5 minutes
    if (cacheDuration <= 0) {
        popupIndex = 0;  // No caching
    } else if (cacheDuration <= 60) {
        popupIndex = 1;  // 1 minute
    } else if (cacheDuration <= 120) {
        popupIndex = 2;  // 2 minutes
    } else if (cacheDuration <= 300) {
        popupIndex = 3;  // 5 minutes
    } else if (cacheDuration <= 600) {
        popupIndex = 4;  // 10 minutes
    } else if (cacheDuration <= 1800) {
        popupIndex = 5;  // 30 minutes
    } else if (cacheDuration <= 3600) {
        popupIndex = 6;  // 1 hour
    } else if (cacheDuration <= 14400) {
        popupIndex = 7;  // 4 hours
    } else if (cacheDuration <= 43200) {
        popupIndex = 8;  // 12 hours
    } else if (cacheDuration <= 86400) {
        popupIndex = 9;  // 1 day
    } else if (cacheDuration <= 172800) {
        popupIndex = 10; // 2 days
    } else if (cacheDuration <= 604800) {
        popupIndex = 11; // 7 days
    } else if (cacheDuration <= 2592000) {
        popupIndex = 12; // 30 days
    } else {
        popupIndex = 13; // 180 days
    }
    [self.cacheDurationPopup selectItemAtIndex:popupIndex];

    // Load display style
    std::string displayStyle = scrobble_config::getWidgetDisplayStyle();
    if (displayStyle == "playback2025") {
        [self.displayStylePopup selectItemAtIndex:1];
    } else {
        [self.displayStylePopup selectItemAtIndex:0];
    }

    // Load streak display setting
    self.streakDisplayCheckbox.state = scrobble_config::isStreakDisplayEnabled() ? NSControlStateValueOn : NSControlStateValueOff;

    // Load glass background setting
    BOOL glassEnabled = scrobble_config::isWidgetGlassBackground();
    self.glassBackgroundCheckbox.state = glassEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    // Load background color
    int64_t argb = scrobble_config::getWidgetBackgroundColor();
    NSColor *bgColor = [self colorFromARGB:(uint32_t)argb];
    self.backgroundColorWell.color = bgColor;
    self.backgroundColorWell.enabled = !glassEnabled;  // Disable when glass is on
}

- (void)saveSettings {
    scrobble_config::setScrobblingEnabled(self.enableScrobblingCheckbox.state == NSControlStateValueOn);
    scrobble_config::setNowPlayingEnabled(self.enableNowPlayingCheckbox.state == NSControlStateValueOn);
    scrobble_config::setLibraryOnlyEnabled(self.libraryOnlyCheckbox.state == NSControlStateValueOn);
    scrobble_config::setDynamicSourcesEnabled(self.dynamicSourcesCheckbox.state == NSControlStateValueOn);
}

- (void)settingsChanged:(id)sender {
    [self saveSettings];
}

- (void)cacheDurationChanged:(id)sender {
    // Map popup index to seconds
    NSInteger index = self.cacheDurationPopup.indexOfSelectedItem;
    int64_t seconds = 300;  // Default 5 minutes
    switch (index) {
        case 0:  seconds = 0; break;         // No caching
        case 1:  seconds = 60; break;        // 1 minute
        case 2:  seconds = 120; break;       // 2 minutes
        case 3:  seconds = 300; break;       // 5 minutes
        case 4:  seconds = 600; break;       // 10 minutes
        case 5:  seconds = 1800; break;      // 30 minutes
        case 6:  seconds = 3600; break;      // 1 hour
        case 7:  seconds = 14400; break;     // 4 hours
        case 8:  seconds = 43200; break;     // 12 hours
        case 9:  seconds = 86400; break;     // 1 day
        case 10: seconds = 172800; break;    // 2 days
        case 11: seconds = 604800; break;    // 7 days
        case 12: seconds = 2592000; break;   // 30 days
        case 13: seconds = 15552000; break;  // 180 days
    }
    scrobble_config::setWidgetCacheDuration(seconds);
}

- (void)displayStyleChanged:(id)sender {
    NSInteger index = self.displayStylePopup.indexOfSelectedItem;
    if (index == 1) {
        scrobble_config::setWidgetDisplayStyle("playback2025");
    } else {
        scrobble_config::setWidgetDisplayStyle("default");
    }

    // Post notification so widget can update
    [[NSNotificationCenter defaultCenter] postNotificationName:ScrobbleSettingsDidChangeNotification
                                                        object:self
                                                      userInfo:@{@"setting": @"displayStyle"}];
}

- (void)streakDisplayChanged:(id)sender {
    scrobble_config::setStreakDisplayEnabled(self.streakDisplayCheckbox.state == NSControlStateValueOn);

    // Post notification so widget can update
    [[NSNotificationCenter defaultCenter] postNotificationName:ScrobbleSettingsDidChangeNotification
                                                        object:self
                                                      userInfo:@{@"setting": @"streakDisplay"}];
}

- (void)glassBackgroundChanged:(id)sender {
    BOOL enabled = (self.glassBackgroundCheckbox.state == NSControlStateValueOn);
    scrobble_config::setWidgetGlassBackground(enabled);

    // Disable color well when glass is on
    self.backgroundColorWell.enabled = !enabled;

    // Post notification so widget can update
    [[NSNotificationCenter defaultCenter] postNotificationName:ScrobbleSettingsDidChangeNotification
                                                        object:self
                                                      userInfo:@{@"setting": @"glassBackground"}];
}

- (void)backgroundColorChanged:(id)sender {
    uint32_t argb = [self argbFromColor:self.backgroundColorWell.color];
    scrobble_config::setWidgetBackgroundColor(argb);

    // Post notification so widget can update
    [[NSNotificationCenter defaultCenter] postNotificationName:ScrobbleSettingsDidChangeNotification
                                                        object:self
                                                      userInfo:@{@"setting": @"backgroundColor"}];
}

#pragma mark - Color Conversion

- (NSColor *)colorFromARGB:(uint32_t)argb {
    // Alpha 0 (transparent/unset) falls back to the system background
    return ScrobbleColorFromARGBOrWindowBackground(argb);
}

- (uint32_t)argbFromColor:(NSColor *)color {
    return ScrobbleARGBFromColor(color);
}

#pragma mark - Authentication

- (void)updateAuthUI {
    LastFmAuth *auth = [LastFmAuth shared];
    LastFmAuthState state = auth.state;

    // Update profile image
    if (auth.profileImage) {
        self.profileImageView.image = auth.profileImage;
        self.profileImageView.contentTintColor = nil;  // Use actual image colors
    } else {
        // Show placeholder
        if (@available(macOS 11.0, *)) {
            self.profileImageView.image = [NSImage imageWithSystemSymbolName:@"person.circle.fill"
                                                    accessibilityDescription:@"Profile"];
            self.profileImageView.contentTintColor = [NSColor tertiaryLabelColor];
        }
    }

    switch (state) {
        case LastFmAuthStateNotAuthenticated:
            self.usernameLabel.stringValue = @"Not signed in";
            self.authStatusLabel.stringValue = @"Sign in to scrobble";
            [self.authButton setTitle:@"Sign In with Last.fm"];
            self.authButton.enabled = YES;
            [self.authSpinner setHidden:YES];
            [self.authSpinner stopAnimation:nil];
            break;

        case LastFmAuthStateRequestingToken:
        case LastFmAuthStateExchangingToken:
            self.usernameLabel.stringValue = @"Connecting...";
            self.authStatusLabel.stringValue = @"";
            self.authButton.enabled = NO;
            [self.authSpinner setHidden:NO];
            [self.authSpinner startAnimation:nil];
            break;

        case LastFmAuthStateWaitingForApproval:
            self.usernameLabel.stringValue = @"Waiting...";
            self.authStatusLabel.stringValue = @"Approve in browser";
            [self.authButton setTitle:@"Cancel"];
            self.authButton.enabled = YES;
            [self.authSpinner setHidden:NO];
            [self.authSpinner startAnimation:nil];
            break;

        case LastFmAuthStateAuthenticated:
            self.usernameLabel.stringValue = auth.username ?: @"";
            self.authStatusLabel.stringValue = @"Signed in";
            [self.authButton setTitle:@"Sign Out"];
            self.authButton.enabled = YES;
            [self.authSpinner setHidden:YES];
            [self.authSpinner stopAnimation:nil];
            break;

        case LastFmAuthStateError:
            self.usernameLabel.stringValue = @"Error";
            self.authStatusLabel.stringValue = auth.errorMessage ?: @"Authentication failed";
            [self.authButton setTitle:@"Try Again"];
            self.authButton.enabled = YES;
            [self.authSpinner setHidden:YES];
            [self.authSpinner stopAnimation:nil];
            break;
    }
}

- (void)authButtonClicked:(id)sender {
    LastFmAuth *auth = [LastFmAuth shared];

    if (auth.state == LastFmAuthStateAuthenticated) {
        // Sign out
        [auth signOut];
    } else if (auth.state == LastFmAuthStateWaitingForApproval) {
        // Cancel
        [auth cancelAuthentication];
    } else {
        // Sign in
        [auth startAuthenticationWithCompletion:^(BOOL success, NSError *error) {
            if (success) {
                // Authentication successful
            } else if (error) {
                // Show error (already handled by updateAuthUI)
            }
        }];
    }
}

- (void)authStateChanged:(NSNotification *)notification {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf updateAuthUI];
    });
}

#pragma mark - Status Updates

- (void)updateStatusLabels {
    NSUInteger pending = [[ScrobbleCache shared] pendingCount];
    NSUInteger inFlight = [[ScrobbleCache shared] inFlightCount];
    NSUInteger sessionCount = [[ScrobbleService shared] sessionScrobbleCount];

    if (inFlight > 0) {
        self.queueStatusLabel.stringValue = [NSString stringWithFormat:@"Queue: %lu pending, %lu submitting",
                                             (unsigned long)pending, (unsigned long)inFlight];
    } else {
        self.queueStatusLabel.stringValue = [NSString stringWithFormat:@"Queue: %lu pending",
                                             (unsigned long)pending];
    }

    self.sessionStatsLabel.stringValue = [NSString stringWithFormat:@"Session: %lu scrobbled",
                                          (unsigned long)sessionCount];
}

- (void)cacheChanged:(NSNotification *)notification {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf updateStatusLabels];
        [weakSelf reloadCacheTable];
    });
}

- (void)serviceStateChanged:(NSNotification *)notification {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf updateStatusLabels];
    });
}

#pragma mark - Cache Table

- (void)reloadCacheTable {
    self.cachedTracks = [[ScrobbleCache shared] pendingTracks];
    [self.cacheTableView reloadData];
    [self updateDeleteButton];
}

- (void)updateDeleteButton {
    self.deleteButton.enabled = (self.cacheTableView.selectedRowIndexes.count > 0);
}

- (void)deleteSelectedTracks:(id)sender {
    NSIndexSet *selected = self.cacheTableView.selectedRowIndexes;
    if (selected.count == 0) return;

    NSString *message;
    if (selected.count == 1) {
        ScrobbleTrack *track = self.cachedTracks[selected.firstIndex];
        message = [NSString stringWithFormat:@"Delete \"%@\" from the scrobble queue?",
                   track.displayDescription];
    } else {
        message = [NSString stringWithFormat:@"Delete %lu tracks from the scrobble queue?",
                   (unsigned long)selected.count];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = @"These tracks will not be scrobbled to Last.fm.";
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;

    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSMutableSet<NSString*> *idsToRemove = [NSMutableSet set];
    [selected enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < self.cachedTracks.count) {
            [idsToRemove addObject:self.cachedTracks[idx].submissionId];
        }
    }];

    [[ScrobbleCache shared] removeTracksWithSubmissionIds:idsToRemove];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.cachedTracks.count;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.cachedTracks.count) return nil;

    ScrobbleTrack *track = self.cachedTracks[row];
    NSString *identifier = tableColumn.identifier;

    NSTextField *cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = identifier;
        cell.font = [NSFont systemFontOfSize:11];
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
    }

    if ([identifier isEqualToString:@"artist"]) {
        cell.stringValue = track.artist ?: @"";
    } else if ([identifier isEqualToString:@"title"]) {
        cell.stringValue = track.title ?: @"";
    } else if ([identifier isEqualToString:@"album"]) {
        cell.stringValue = track.album ?: @"";
    } else if ([identifier isEqualToString:@"date"]) {
        if (track.timestamp > 0) {
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)track.timestamp];
            cell.stringValue = [self.dateFormatter stringFromDate:date];
        } else {
            cell.stringValue = @"";
        }
    }

    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateDeleteButton];
}

@end
