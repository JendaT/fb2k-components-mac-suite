//
//  ScrobblePreferencesController.mm
//  foo_scrobble_mac
//
//  Preferences page implementation
//

#import "ScrobblePreferencesController.h"
#import "../Core/ScrobbleConfig.h"
#import "../Core/ScrobbleNotifications.h"
#import "../LastFm/LastFmAuth.h"
#import "../Services/ScrobbleService.h"
#import "../Services/ScrobbleCache.h"
#import "../../../../shared/PreferencesCommon.h"

@interface ScrobblePreferencesController ()
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

// Status labels
@property (nonatomic, strong) NSTextField *queueStatusLabel;
@property (nonatomic, strong) NSTextField *sessionStatsLabel;
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
}

#pragma mark - Settings

- (void)loadSettings {
    self.enableScrobblingCheckbox.state = scrobble_config::isScrobblingEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    self.enableNowPlayingCheckbox.state = scrobble_config::isNowPlayingEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    self.libraryOnlyCheckbox.state = scrobble_config::isLibraryOnlyEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    self.dynamicSourcesCheckbox.state = scrobble_config::isDynamicSourcesEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
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
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateAuthUI];
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
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusLabels];
    });
}

- (void)serviceStateChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusLabels];
    });
}

@end
