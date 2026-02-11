//
//  TidalPreferencesController.mm
//  foo_jl_tidal_mac
//
//  Preferences page implementation - styled like scrobble plugin
//

#import "TidalPreferencesController.h"
#import "../Services/TidalAuthService.h"
#import "../Core/TidalConfig.h"
#import "../API/TidalConstants.h"
#import "../API/TidalAPI.h"
#import "../../../../shared/PreferencesCommon.h"

@interface JLTidalPreferencesController ()
// Authentication UI
@property (nonatomic, strong) NSImageView *profileImageView;
@property (nonatomic, strong) NSTextField *usernameLabel;
@property (nonatomic, strong) NSTextField *authStatusLabel;
@property (nonatomic, strong) NSButton *authButton;
@property (nonatomic, strong, readwrite) NSButton *reconnectButton;
@property (nonatomic, strong) NSProgressIndicator *authSpinner;
@property (nonatomic, strong) NSTextField *userCodeLabel;

// Settings
@property (nonatomic, strong) NSPopUpButton *qualityPopup;
@property (nonatomic, strong) NSButton *debugCheckbox;

// Cached user info
@property (nonatomic, strong) NSImage *cachedProfileImage;
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
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 450, 350)];

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
                [status appendString:@" - Token expired"];
                self.authStatusLabel.textColor = [NSColor systemOrangeColor];
                self.reconnectButton.hidden = NO;
                self.reconnectButton.enabled = YES;
            } else {
                self.authStatusLabel.textColor = [NSColor secondaryLabelColor];
                self.reconnectButton.hidden = YES;
            }
            self.authStatusLabel.stringValue = status;

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

    // Try refreshing the token first
    [[JLTidalAuthService shared] refreshTokenIfNeededWithCompletion:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                // Token refreshed - updateAuthUI will be called via notification
                tidal::logInfo("Reconnect: token refreshed successfully");
            } else {
                // Refresh failed - start full OAuth flow
                tidal::logInfo("Reconnect: refresh failed, starting full OAuth flow");
                [[JLTidalAuthService shared] startAuthenticationWithCompletion:^(BOOL authSuccess, NSError *error) {
                    if (!authSuccess && error) {
                        tidal::logError([[NSString stringWithFormat:@"Reconnect auth failed: %@",
                                         error.localizedDescription] UTF8String]);
                    }
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

@end
