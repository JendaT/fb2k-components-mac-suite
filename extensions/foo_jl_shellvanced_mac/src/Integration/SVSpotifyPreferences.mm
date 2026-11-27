//
//  SVSpotifyPreferences.mm
//  foo_jl_shellvanced_mac
//

#import "SVSpotifyPreferences.h"
#include "../fb2k_sdk.h"
#import "../Artists/SVSpotifyClient.h"
#import "../Artists/SVSpotifyCredentials.h"
#import "../Artists/SVArtistImageProvider.h"
#import "../../../../shared/PreferencesCommon.h"

@interface SVPrefsFlippedView : NSView
@end
@implementation SVPrefsFlippedView
- (BOOL)isFlipped { return YES; }
@end

@implementation SVSpotifyPreferences {
    NSTextField *_idField;
    NSSecureTextField *_secretField;
    NSTextField *_status;
    NSButton *_testButton;
}

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (NSString *)preferencesTitle { return @"ShellVanced"; }

- (void)loadView {
    self.view = [[SVPrefsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 450, 230)];
    [self buildUI];
}

- (void)buildUI {
    CGFloat y = 10, x = JLPrefsLeftMargin, fieldX = x + JLPrefsLabelWidth;

    NSTextField *title = JLCreatePreferencesTitle(@"ShellVanced");
    title.frame = NSMakeRect(x, y, 400, 20);
    [self.view addSubview:title];
    y += 28;

    NSTextField *header = JLCreateSectionHeader(@"Spotify artist photos (optional)");
    header.frame = NSMakeRect(x, y, 300, 17);
    [self.view addSubview:header];
    y += 24;

    NSTextField *idLabel = JLCreateLabel(@"Client ID:");
    idLabel.frame = NSMakeRect(x + JLPrefsIndent, y + 3, JLPrefsLabelWidth - JLPrefsIndent, 16);
    [self.view addSubview:idLabel];
    _idField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, y, 280, 22)];
    _idField.stringValue = [SVSpotifyCredentials clientId] ?: @"";
    [self.view addSubview:_idField];
    y += 30;

    NSTextField *secretLabel = JLCreateLabel(@"Client Secret:");
    secretLabel.frame = NSMakeRect(x + JLPrefsIndent, y + 3, JLPrefsLabelWidth - JLPrefsIndent, 16);
    [self.view addSubview:secretLabel];
    _secretField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, y, 280, 22)];
    _secretField.placeholderString = [SVSpotifyCredentials clientSecret].length ? @"(stored in Keychain)" : @"";
    [self.view addSubview:_secretField];
    y += 34;

    _testButton = [NSButton buttonWithTitle:@"Test" target:self action:@selector(test:)];
    _testButton.frame = NSMakeRect(fieldX, y, 70, 24);
    [self.view addSubview:_testButton];
    NSButton *save = [NSButton buttonWithTitle:@"Save" target:self action:@selector(save:)];
    save.frame = NSMakeRect(fieldX + 78, y, 70, 24);
    [self.view addSubview:save];
    NSButton *remove = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(remove:)];
    remove.frame = NSMakeRect(fieldX + 156, y, 76, 24);
    [self.view addSubview:remove];
    _status = JLCreateHelperText(@"");
    _status.frame = NSMakeRect(fieldX + 240, y + 5, 160, 14);
    [self.view addSubview:_status];
    y += 38;

    NSTextField *help = [NSTextField wrappingLabelWithString:
        @"Used only for artists without a photo on Deezer. Create an app at developer.spotify.com/dashboard and paste its Client ID and Secret."];
    help.font = [NSFont systemFontOfSize:10];
    help.textColor = [NSColor tertiaryLabelColor];
    help.frame = NSMakeRect(x + JLPrefsIndent, y, 400, 42);
    [self.view addSubview:help];
}

// Field values, falling back to the stored secret when the secret field was left empty.
- (void)currentId:(NSString **)cid secret:(NSString **)secret {
    *cid = [_idField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *s = [_secretField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    *secret = s.length ? s : ([SVSpotifyCredentials clientSecret] ?: @"");
}

- (void)setStatus:(NSString *)text {
    _status.stringValue = text;
}

- (void)test:(id)sender {
    NSString *cid, *secret;
    [self currentId:&cid secret:&secret];
    [self setStatus:@"Testing..."];
    _testButton.enabled = NO;
    [[SVSpotifyClient shared] testClientId:cid secret:secret completion:^(BOOL ok, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_testButton.enabled = YES;
            [self setStatus:message];
        });
    }];
}

// Applies a credentials change. The rate-limit block survives unless a new Client ID differs from the blocked one.
- (void)applyChangeWithNewClientId:(NSString *)newId {
    [[SVSpotifyClient shared] credentialsChangedWithNewClientId:newId];
    [[SVArtistImageProvider shared] spotifyCredentialsDidChange];
}

- (void)refreshSecretPlaceholder {
    _secretField.stringValue = @"";
    _secretField.placeholderString = [SVSpotifyCredentials clientSecret].length ? @"(stored in Keychain)" : @"";
}

- (void)save:(id)sender {
    NSString *cid, *secret;
    [self currentId:&cid secret:&secret];
    NSString *oldId = [SVSpotifyCredentials clientId] ?: @"", *oldSecret = [SVSpotifyCredentials clientSecret] ?: @"";
    const BOOL idChanged = ![cid isEqualToString:oldId];
    const BOOL changed = idChanged || ![secret isEqualToString:oldSecret];
    if (!changed) { [self setStatus:@"Nothing changed"]; [self refreshSecretPlaceholder]; return; }
    BOOL ok = [SVSpotifyCredentials saveClientId:cid secret:secret];
    [self refreshSecretPlaceholder];
    [self setStatus:ok ? @"Saved" : @"Keychain write failed"];
    if (ok) [self applyChangeWithNewClientId:cid];
}

- (void)remove:(id)sender {
    const BOOL had = [SVSpotifyCredentials isConfigured] || [SVSpotifyCredentials clientId].length;
    [SVSpotifyCredentials saveClientId:nil secret:nil];
    _idField.stringValue = @"";
    [self refreshSecretPlaceholder];
    [self setStatus:@"Removed"];
    if (had) [self applyChangeWithNewClientId:nil];
}

@end

namespace {
    // uuidgen: A379DE43-329E-4EF8-A358-E53592746F0D
    static const GUID guid_shellvanced_preferences = {
        0xa379de43, 0x329e, 0x4ef8,
        {0xa3, 0x58, 0xe5, 0x35, 0x92, 0x74, 0x6f, 0x0d}
    };

    class shellvanced_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            return fb2k::wrapNSObject([[SVSpotifyPreferences alloc] init]);
        }
        const char* get_name() override { return "ShellVanced"; }
        GUID get_guid() override { return guid_shellvanced_preferences; }
        GUID get_parent_guid() override { return preferences_page::guid_display; }
    };

    FB2K_SERVICE_FACTORY(shellvanced_preferences_page);
}
