//
//  TidalPreferencesController.mm
//  foo_jl_tidal_mac
//
//  Preferences page implementation - styled like scrobble plugin
//

#import "TidalPreferencesController.h"
#import "../Services/TidalAuthService.h"
#import "../Core/TidalConfig.h"
#import "../Core/StreamCache.h"
#import "../API/TidalConstants.h"
#import "../API/TidalAPI.h"
#import "../../../../shared/PreferencesCommon.h"

@interface JLTidalPreferencesController ()
// Authentication UI
@property (nonatomic, strong) NSImageView *profileImageView;
@property (nonatomic, strong) NSTextField *usernameLabel;
@property (nonatomic, strong) NSTextField *authStatusLabel;
@property (nonatomic, strong) NSTextField *tokenStatusLabel;
@property (nonatomic, strong) NSButton *authButton;
@property (nonatomic, strong, readwrite) NSButton *reconnectButton;
@property (nonatomic, strong) NSProgressIndicator *authSpinner;
@property (nonatomic, strong) NSTextField *userCodeLabel;

// Settings
@property (nonatomic, strong) NSPopUpButton *qualityPopup;
@property (nonatomic, strong) NSButton *debugCheckbox;
@property (nonatomic, strong) NSButton *dashCheckbox;
@property (nonatomic, strong) NSTextField *libraryPathField;

// Cached user info
@property (nonatomic, strong) NSImage *cachedProfileImage;

// Token countdown timer
@property (nonatomic, strong) NSTimer *tokenStatusTimer;
@end

@implementation JLTidalPreferencesController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(authStateChanged:)
                                                     name:JLTidalAuthStateDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [_tokenStatusTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    // Update token status every 15 seconds while view is visible
    [self.tokenStatusTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.tokenStatusTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                           repeats:YES
                                                             block:^(NSTimer *t) {
        [weakSelf updateAuthUI];
    }];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self.tokenStatusTimer invalidate];
    self.tokenStatusTimer = nil;
}

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 450, 480)];

    CGFloat leftMargin = 20;
    __block CGFloat currentY = 20;
    CGFloat rowHeight = 24;
    CGFloat sectionGap = 16;

    // Helper to add a view
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

    // ===== Title =====
    NSTextField *title = JLCreatePreferencesTitle(@"Tidal Integration");
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

    self.tokenStatusLabel = [NSTextField labelWithString:@""];
    self.tokenStatusLabel.font = [NSFont systemFontOfSize:10];
    self.tokenStatusLabel.textColor = [NSColor tertiaryLabelColor];
    self.tokenStatusLabel.hidden = YES;
    self.tokenStatusLabel.maximumNumberOfLines = 0;
    self.tokenStatusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [self.tokenStatusLabel.cell setWraps:YES];
    [infoStack addArrangedSubview:self.tokenStatusLabel];

    [profileRow addArrangedSubview:infoStack];

    self.authSpinner = [[NSProgressIndicator alloc] init];
    self.authSpinner.style = NSProgressIndicatorStyleSpinning;
    self.authSpinner.controlSize = NSControlSizeSmall;
    [self.authSpinner setHidden:YES];
    [profileRow addArrangedSubview:self.authSpinner];

    addIndentedRow(profileRow, 56);

    // User code label (shown during auth)
    self.userCodeLabel = [NSTextField labelWithString:@""];
    self.userCodeLabel.font = [NSFont monospacedSystemFontOfSize:24 weight:NSFontWeightMedium];
    self.userCodeLabel.hidden = YES;
    addIndentedRow(self.userCodeLabel, 36);

    // Auth buttons row (Reconnect + Disconnect side by side when expired)
    NSStackView *authButtonRow = [[NSStackView alloc] init];
    authButtonRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    authButtonRow.spacing = 8;

    self.reconnectButton = [NSButton buttonWithTitle:@"Reconnect"
                                              target:self
                                              action:@selector(reconnectButtonClicked:)];
    self.reconnectButton.hidden = YES;
    [authButtonRow addArrangedSubview:self.reconnectButton];

    self.authButton = [NSButton buttonWithTitle:@"Connect to Tidal"
                                         target:self
                                         action:@selector(authButtonClicked:)];
    [authButtonRow addArrangedSubview:self.authButton];

    addIndentedRow(authButtonRow, 32 + sectionGap);

    // ===== Audio Quality Section =====
    NSTextField *qualityLabel = [NSTextField labelWithString:@"Audio Quality"];
    qualityLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    qualityLabel.textColor = [NSColor secondaryLabelColor];
    addRow(qualityLabel, rowHeight);

    self.qualityPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.qualityPopup addItemWithTitle:@"HiFi Plus (up to 24-bit/192kHz)"];
    [self.qualityPopup addItemWithTitle:@"HiFi (up to 24-bit/96kHz MQA)"];
    [self.qualityPopup addItemWithTitle:@"Lossless (16-bit/44.1kHz FLAC)"];
    [self.qualityPopup addItemWithTitle:@"High (320kbps AAC)"];
    [self.qualityPopup addItemWithTitle:@"Normal (96kbps AAC)"];
    [self.qualityPopup setTarget:self];
    [self.qualityPopup setAction:@selector(qualityChanged:)];
    addIndentedRow(self.qualityPopup, rowHeight + 4);

    NSTextField *qualityNote = [NSTextField wrappingLabelWithString:
        @"Actual quality depends on your Tidal subscription. "
        @"DRM-protected HiFi content falls back to lower quality."];
    qualityNote.textColor = [NSColor tertiaryLabelColor];
    qualityNote.font = [NSFont systemFontOfSize:10];
    [qualityNote.widthAnchor constraintLessThanOrEqualToConstant:380].active = YES;
    addIndentedRow(qualityNote, 36 + sectionGap);

    // ===== Debug Section =====
    NSTextField *debugLabel = [NSTextField labelWithString:@"Advanced"];
    debugLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    debugLabel.textColor = [NSColor secondaryLabelColor];
    addRow(debugLabel, rowHeight);

    self.debugCheckbox = [NSButton checkboxWithTitle:@"Enable debug logging"
                                              target:self
                                              action:@selector(debugChanged:)];
    addIndentedRow(self.debugCheckbox, rowHeight);

    self.dashCheckbox = [NSButton checkboxWithTitle:@"Download LOSSLESS via DASH segments"
                                             target:self
                                             action:@selector(dashChanged:)];
    addIndentedRow(self.dashCheckbox, rowHeight + sectionGap);

    // ===== Library Section (personal music.hq export) =====
    NSTextField *libraryLabel = [NSTextField labelWithString:@"Library"];
    libraryLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    libraryLabel.textColor = [NSColor secondaryLabelColor];
    addRow(libraryLabel, rowHeight);

    NSStackView *libraryRow = [[NSStackView alloc] init];
    libraryRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    libraryRow.spacing = 8;

    self.libraryPathField = [NSTextField labelWithString:@"Not configured"];
    self.libraryPathField.font = [NSFont systemFontOfSize:11];
    self.libraryPathField.textColor = [NSColor secondaryLabelColor];
    self.libraryPathField.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.libraryPathField.widthAnchor constraintLessThanOrEqualToConstant:250].active = YES;
    [libraryRow addArrangedSubview:self.libraryPathField];

    NSButton *chooseButton = [NSButton buttonWithTitle:@"Choose…"
                                                target:self
                                                action:@selector(chooseLibraryRoot:)];
    chooseButton.controlSize = NSControlSizeSmall;
    [libraryRow addArrangedSubview:chooseButton];

    NSButton *clearButton = [NSButton buttonWithTitle:@"Clear"
                                               target:self
                                               action:@selector(clearLibraryRoot:)];
    clearButton.controlSize = NSControlSizeSmall;
    [libraryRow addArrangedSubview:clearButton];

    addIndentedRow(libraryRow, rowHeight);

    NSTextField *libraryNote = [NSTextField wrappingLabelWithString:
        @"Enables \"Save to library\" in the playlist context menu: selected tracks "
        @"are downloaded into this folder using the music.hq layout. Leave unset to "
        @"disable the feature."];
    libraryNote.textColor = [NSColor tertiaryLabelColor];
    libraryNote.font = [NSFont systemFontOfSize:10];
    [libraryNote.widthAnchor constraintLessThanOrEqualToConstant:380].active = YES;
    addIndentedRow(libraryNote, 40);

    self.view = container;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadSettings];
    [self updateAuthUI];
}

- (void)loadSettings {
    // Quality
    JLTidalQuality quality = tidal::TidalConfig::getPreferredQuality();
    NSInteger index = 0;
    switch (quality) {
        case JLTidalQualityHiResLossless: index = 0; break;
        case JLTidalQualityHiRes: index = 1; break;
        case JLTidalQualityLossless: index = 2; break;
        case JLTidalQualityHigh: index = 3; break;
        case JLTidalQualityLow: index = 4; break;
    }
    [self.qualityPopup selectItemAtIndex:index];

    // Debug
    self.debugCheckbox.state = tidal::TidalConfig::isDebugLoggingEnabled() ? NSControlStateValueOn : NSControlStateValueOff;

    // DASH experimental toggle
    self.dashCheckbox.state = tidal::TidalConfig::isDASHEnabled() ? NSControlStateValueOn : NSControlStateValueOff;

    [self updateLibraryPathField];
}

- (void)updateLibraryPathField {
    std::string root = tidal::TidalConfig::getLibraryRoot();
    if (root.empty()) {
        self.libraryPathField.stringValue = @"Not configured";
        self.libraryPathField.textColor = [NSColor secondaryLabelColor];
    } else {
        self.libraryPathField.stringValue = [NSString stringWithUTF8String:root.c_str()];
        self.libraryPathField.textColor = [NSColor labelColor];
    }
}

- (void)updateAuthUI {
    JLTidalAuthState state = [[JLTidalAuthService shared] state];
    JLTidalSession *session = [[JLTidalAuthService shared] session];

    // Update profile image
    if (self.cachedProfileImage) {
        self.profileImageView.image = self.cachedProfileImage;
        self.profileImageView.contentTintColor = nil;
    } else {
        if (@available(macOS 11.0, *)) {
            self.profileImageView.image = [NSImage imageWithSystemSymbolName:@"person.circle.fill"
                                                    accessibilityDescription:@"Profile"];
            self.profileImageView.contentTintColor = [NSColor tertiaryLabelColor];
        }
    }

    // Hide token detail label in non-authenticated states; will be re-shown if needed below
    self.tokenStatusLabel.hidden = YES;

    switch (state) {
        case JLTidalAuthStateIdle:
            self.usernameLabel.stringValue = @"Not signed in";
            self.authStatusLabel.stringValue = @"Sign in to play Tidal music";
            [self.authButton setTitle:@"Connect to Tidal"];
            self.authButton.enabled = YES;
            self.userCodeLabel.hidden = YES;
            self.reconnectButton.hidden = YES;
            [self.authSpinner setHidden:YES];
            [self.authSpinner stopAnimation:nil];
            break;

        case JLTidalAuthStateRequestingDeviceCode:
            self.usernameLabel.stringValue = @"Connecting...";
            self.authStatusLabel.stringValue = @"";
            self.authButton.enabled = NO;
            self.userCodeLabel.hidden = YES;
            self.reconnectButton.hidden = YES;
            [self.authSpinner setHidden:NO];
            [self.authSpinner startAnimation:nil];
            break;

        case JLTidalAuthStateWaitingForApproval: {
            NSString *userCode = [[JLTidalAuthService shared] userCode];
            self.usernameLabel.stringValue = @"Enter code at link.tidal.com:";
            self.authStatusLabel.stringValue = @"";
            self.userCodeLabel.stringValue = userCode ?: @"";
            self.userCodeLabel.hidden = NO;
            self.reconnectButton.hidden = YES;
            [self.authButton setTitle:@"Cancel"];
            self.authButton.enabled = YES;
            [self.authSpinner setHidden:NO];
            [self.authSpinner startAnimation:nil];
            break;
        }

        case JLTidalAuthStateExchangingToken:
            self.usernameLabel.stringValue = @"Completing...";
            self.authStatusLabel.stringValue = @"";
            self.authButton.enabled = NO;
            self.userCodeLabel.hidden = YES;
            self.reconnectButton.hidden = YES;
            [self.authSpinner setHidden:NO];
            [self.authSpinner startAnimation:nil];
            break;

        case JLTidalAuthStateAuthenticated: {
            // Show user info
            NSString *displayName = session.username;
            if (!displayName.length && session.userId.length) {
                displayName = [NSString stringWithFormat:@"User %@", session.userId];
            }
            if (!displayName.length) {
                displayName = @"Tidal User";
            }
            self.usernameLabel.stringValue = displayName;

            // Show status with country code
            NSMutableString *status = [NSMutableString stringWithString:@"Signed in"];
            if (session.countryCode.length > 0) {
                [status appendFormat:@" [%@]", session.countryCode];
            }
            if (session.isExpired) {
                [status appendString:@" — Token expired"];
                self.authStatusLabel.textColor = [NSColor systemOrangeColor];
                self.reconnectButton.hidden = NO;
                self.reconnectButton.enabled = YES;
            } else {
                self.authStatusLabel.textColor = [NSColor secondaryLabelColor];
                self.reconnectButton.hidden = YES;
            }
            self.authStatusLabel.stringValue = status;

            // Token detail line: expiry countdown + warning state
            self.tokenStatusLabel.hidden = NO;
            self.tokenStatusLabel.stringValue = [self formatTokenStatus:session];
            if (session.isExpired) {
                self.tokenStatusLabel.textColor = [NSColor systemOrangeColor];
            } else if (session.needsRefresh) {
                self.tokenStatusLabel.textColor = [NSColor systemYellowColor];
            } else {
                self.tokenStatusLabel.textColor = [NSColor tertiaryLabelColor];
            }

            [self.authButton setTitle:@"Disconnect"];
            self.authButton.enabled = YES;
            self.userCodeLabel.hidden = YES;
            [self.authSpinner setHidden:YES];
            [self.authSpinner stopAnimation:nil];

            // Fetch user profile if we don't have it
            [self fetchUserProfileIfNeeded];
            break;
        }

        case JLTidalAuthStateCancelled:
            self.usernameLabel.stringValue = @"Cancelled";
            self.authStatusLabel.stringValue = @"Authentication cancelled";
            [self.authButton setTitle:@"Connect to Tidal"];
            self.authButton.enabled = YES;
            self.userCodeLabel.hidden = YES;
            self.reconnectButton.hidden = YES;
            [self.authSpinner setHidden:YES];
            [self.authSpinner stopAnimation:nil];
            break;

        case JLTidalAuthStateError: {
            NSString *error = [[JLTidalAuthService shared] errorMessage] ?: @"Authentication failed";
            self.usernameLabel.stringValue = @"Error";
            self.authStatusLabel.stringValue = error;
            self.authStatusLabel.textColor = [NSColor systemRedColor];
            [self.authButton setTitle:@"Try Again"];
            self.authButton.enabled = YES;
            self.userCodeLabel.hidden = YES;
            self.reconnectButton.hidden = YES;
            [self.authSpinner setHidden:YES];
            [self.authSpinner stopAnimation:nil];
            break;
        }
    }
}

- (NSString *)formatTokenStatus:(JLTidalSession *)session {
    if (!session) return @"";

    NSTimeInterval secondsLeft = [session.expiryDate timeIntervalSinceNow];
    NSString *base;
    if (secondsLeft <= 0) {
        NSTimeInterval ago = -secondsLeft;
        base = [NSString stringWithFormat:@"Token expired %@ ago — playback will fail until reconnect",
                [self formatDuration:ago]];
    } else if (secondsLeft < 300) {
        base = [NSString stringWithFormat:@"Token expires in %@ — refreshing soon",
                [self formatDuration:secondsLeft]];
    } else {
        base = [NSString stringWithFormat:@"Token valid · expires in %@",
                [self formatDuration:secondsLeft]];
    }

    JLTidalAuthService *svc = [JLTidalAuthService shared];
    NSDate *lastAttempt = svc.lastRefreshAttempt;
    if (lastAttempt) {
        NSTimeInterval since = -[lastAttempt timeIntervalSinceNow];
        NSString *whenStr = [self formatDuration:since];
        if (svc.lastRefreshError) {
            base = [base stringByAppendingFormat:@"\nLast refresh: failed %@ ago — %@",
                    whenStr, svc.lastRefreshError];
        } else {
            base = [base stringByAppendingFormat:@"\nLast refresh: ok %@ ago", whenStr];
        }
    }
    return base;
}

- (NSString *)formatDuration:(NSTimeInterval)seconds {
    if (seconds < 0) seconds = 0;
    long s = (long)seconds;
    long h = s / 3600;
    long m = (s % 3600) / 60;
    long sec = s % 60;
    if (h > 0) {
        return [NSString stringWithFormat:@"%ldh %ldm", h, m];
    } else if (m > 0) {
        return [NSString stringWithFormat:@"%ldm %lds", m, sec];
    } else {
        return [NSString stringWithFormat:@"%lds", sec];
    }
}

- (void)fetchUserProfileIfNeeded {
    // For now, we don't have user profile API - would need to add Tidal user endpoint
    // This is a placeholder for when we add /v1/users/me endpoint support
}

- (void)authStateChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateAuthUI];
    });
}

- (void)authButtonClicked:(id)sender {
    JLTidalAuthState state = [[JLTidalAuthService shared] state];

    if (state == JLTidalAuthStateAuthenticated) {
        [[JLTidalAuthService shared] signOut];
        self.cachedProfileImage = nil;
    } else if (state == JLTidalAuthStateWaitingForApproval ||
               state == JLTidalAuthStateRequestingDeviceCode) {
        [[JLTidalAuthService shared] cancelAuthentication];
    } else {
        [[JLTidalAuthService shared] startAuthenticationWithCompletion:^(BOOL success, NSError *error) {
            if (!success && error) {
                tidal::logError([[NSString stringWithFormat:@"Auth failed: %@", error.localizedDescription] UTF8String]);
            }
        }];
    }
}

- (void)reconnectButtonClicked:(id)sender {
    // Show reconnecting state
    self.reconnectButton.enabled = NO;
    self.authStatusLabel.stringValue = @"Reconnecting...";
    self.authStatusLabel.textColor = [NSColor secondaryLabelColor];
    [self.authSpinner setHidden:NO];
    [self.authSpinner startAnimation:nil];

    tidal::logInfo("Reconnect: starting token refresh");

    // Try refreshing the token first
    __weak typeof(self) weakSelf = self;
    [[JLTidalAuthService shared] refreshTokenIfNeededWithCompletion:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (success) {
                tidal::logInfo("Reconnect: token refreshed successfully");
                // State was already Authenticated, so setState: won't fire a notification.
                // Must update UI explicitly.
                [strongSelf updateAuthUI];
            } else {
                // Refresh failed - sign out cleanly, then start full OAuth flow
                tidal::logInfo("Reconnect: refresh failed, starting full OAuth flow");
                [[JLTidalAuthService shared] signOut];
                [[JLTidalAuthService shared] startAuthenticationWithCompletion:^(BOOL authSuccess, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        typeof(self) strongSelf2 = weakSelf;
                        if (!strongSelf2) return;
                        if (!authSuccess) {
                            tidal::logError([[NSString stringWithFormat:@"Reconnect auth failed: %@",
                                             error.localizedDescription ?: @"unknown"] UTF8String]);
                            // Ensure UI recovers from "Reconnecting..." state
                            [strongSelf2 updateAuthUI];
                        }
                    });
                }];
            }
        });
    }];
}

- (void)qualityChanged:(id)sender {
    NSInteger index = [self.qualityPopup indexOfSelectedItem];
    JLTidalQuality quality;
    switch (index) {
        case 0: quality = JLTidalQualityHiResLossless; break;
        case 1: quality = JLTidalQualityHiRes; break;
        case 2: quality = JLTidalQualityLossless; break;
        case 3: quality = JLTidalQualityHigh; break;
        case 4: quality = JLTidalQualityLow; break;
        default: quality = JLTidalQualityHiResLossless; break;
    }
    tidal::TidalConfig::setPreferredQuality(quality);
}

- (void)debugChanged:(id)sender {
    bool enabled = (self.debugCheckbox.state == NSControlStateValueOn);
    tidal::TidalConfig::setDebugLoggingEnabled(enabled);
}

- (void)chooseLibraryRoot:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.message = @"Choose the music library root (e.g. music.hq)";
    if ([panel runModal] == NSModalResponseOK && panel.URL.path.length > 0) {
        tidal::TidalConfig::setLibraryRoot(std::string(panel.URL.path.UTF8String));
        [self updateLibraryPathField];
    }
}

- (void)clearLibraryRoot:(id)sender {
    tidal::TidalConfig::setLibraryRoot("");
    [self updateLibraryPathField];
}

- (void)dashChanged:(id)sender {
    bool enabled = (self.dashCheckbox.state == NSControlStateValueOn);
    tidal::TidalConfig::setDASHEnabled(enabled);
    // Stream cache may hold pre-DASH entries — clear so the next play re-resolves
    // and picks up DASH-vs-direct selection based on the new setting.
    tidal::StreamCache::shared().clear();
}

@end
