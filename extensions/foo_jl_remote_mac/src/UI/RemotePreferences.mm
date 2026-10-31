//
//  RemotePreferences.mm
//  foo_jl_remote_mac
//

#import "RemotePreferences.h"
#include "../fb2k_sdk.h"
#include "../Core/RemoteConfig.h"
#import "../Integration/RemoteServer.h"
#import "../../../../shared/PreferencesCommon.h"

#import <CoreImage/CoreImage.h>

// Uniquely-named flipped view (avoids ObjC runtime clashes across components)
@interface RemoteFlippedView : NSView
@end
@implementation RemoteFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface RemotePreferences () <NSTextFieldDelegate> {
    NSButton    *_enabledCheckbox;
    NSTextField *_portField;
    NSTextField *_statusLabel;
    NSTextField *_urlsLabel;
    NSImageView *_qrView;
    id           _statusObserver;
}
@end

@implementation RemotePreferences

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (void)dealloc {
    if (_statusObserver) [[NSNotificationCenter defaultCenter] removeObserver:_statusObserver];
}

- (NSString *)preferencesTitle { return @"LAN Remote"; }

- (void)loadView {
    RemoteFlippedView *view = [[RemoteFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 460, 470)];
    self.view = view;
    [self buildUI];

    __weak RemotePreferences *weakSelf = self;
    _statusObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:RemoteServerStatusChangedNotification object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *) { [weakSelf refresh]; }];
    [self refresh];
}

- (void)buildUI {
    CGFloat y = 10;
    const CGFloat labelX = JLPrefsLeftMargin;
    const CGFloat controlX = 150;

    NSTextField *title = JLCreatePreferencesTitle(@"LAN Remote");
    title.frame = NSMakeRect(labelX, y, 400, 20);
    [self.view addSubview:title];
    y += 30;

    // --- Server ---
    NSTextField *serverHeader = JLCreateSectionHeader(@"Server");
    serverHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:serverHeader];
    y += 22;

    _enabledCheckbox = [NSButton checkboxWithTitle:@"Enable remote control" target:self action:@selector(enabledChanged:)];
    _enabledCheckbox.frame = NSMakeRect(labelX + 10, y, 300, 20);
    [self.view addSubview:_enabledCheckbox];
    y += 28;

    NSTextField *portLabel = JLCreateLabel(@"Port:");
    portLabel.frame = NSMakeRect(labelX + 10, y + 3, 120, 17);
    [self.view addSubview:portLabel];
    _portField = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX, y, 70, 22)];
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.allowsFloats = NO;
    formatter.usesGroupingSeparator = NO;
    formatter.minimum = @(remote_config::kMinPort);
    formatter.maximum = @(remote_config::kMaxPort);
    _portField.formatter = formatter;
    _portField.delegate = self;
    _portField.target = self;
    _portField.action = @selector(portChanged:);
    _portField.toolTip = @"TCP port the remote listens on (1024-65535)";
    [self.view addSubview:_portField];
    y += 30;

    NSTextField *statusCaption = JLCreateLabel(@"Status:");
    statusCaption.frame = NSMakeRect(labelX + 10, y, 120, 17);
    [self.view addSubview:statusCaption];
    _statusLabel = JLCreateLabel(@"");
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.frame = NSMakeRect(controlX, y, 290, 17);
    [self.view addSubview:_statusLabel];
    y += 34;

    // --- Phone ---
    NSTextField *phoneHeader = JLCreateSectionHeader(@"Open on your phone");
    phoneHeader.frame = NSMakeRect(labelX, y, 300, 17);
    [self.view addSubview:phoneHeader];
    y += 22;

    _urlsLabel = JLCreateLabel(@"");
    _urlsLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    _urlsLabel.selectable = YES;
    _urlsLabel.frame = NSMakeRect(labelX + 10, y, 410, 40);
    [self.view addSubview:_urlsLabel];
    y += 46;

    _qrView = [[NSImageView alloc] initWithFrame:NSMakeRect(labelX + 10, y, 180, 180)];
    _qrView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _qrView.toolTip = @"Scan with the phone's camera";
    [self.view addSubview:_qrView];
    y += 190;

    NSTextField *helper = JLCreateHelperText(
        @"The phone must be on the same Wi-Fi as this Mac. Only devices on the local\n"
        @"network can connect. In Chrome, use ⋮ > Add to Home screen for an app icon.\n"
        @"Volume range and step size are set in the remote's own settings.");
    helper.frame = NSMakeRect(labelX + 10, y, 420, 42);
    [self.view addSubview:helper];
}

- (void)refresh {
    RemoteServer *server = [RemoteServer shared];
    const bool enabled = remote_config::isEnabled();

    _enabledCheckbox.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (_portField.currentEditor == nil) _portField.integerValue = remote_config::port();
    _portField.enabled = enabled;
    _statusLabel.stringValue = server.statusText;

    NSArray<NSString *> *urls = server.isListening ? [server localURLs] : @[];
    if (urls.count > 0) {
        _urlsLabel.stringValue = [urls componentsJoinedByString:@"\n"];
        _qrView.image = [self qrImageForString:urls.firstObject];
    } else {
        _urlsLabel.stringValue = server.isListening ? @"No local network connection found" : @"—";
        _qrView.image = nil;
    }
}

- (nullable NSImage *)qrImageForString:(NSString *)string {
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[string dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *code = filter.outputImage;
    if (!code) return nil;

    // Integral nearest-neighbour scale keeps module edges sharp for scanners.
    const CGFloat scale = 8;
    CIImage *scaled = [[code imageBySamplingNearest]
                       imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:scaled];
    NSImage *image = [[NSImage alloc] initWithSize:rep.size];
    [image addRepresentation:rep];
    return image;
}

- (void)enabledChanged:(id)sender {
    remote_config::setEnabled(_enabledCheckbox.state == NSControlStateValueOn);
    [[RemoteServer shared] applyConfig];
    [self refresh];
}

- (void)portChanged:(id)sender {
    const NSInteger port = _portField.integerValue;
    if (port < remote_config::kMinPort || port > remote_config::kMaxPort) {
        _portField.integerValue = remote_config::port();
        return;
    }
    if (port == remote_config::port()) return;
    remote_config::setPort((int)port);
    [[RemoteServer shared] applyConfig];
    [self refresh];
}

// Commit the port when focus leaves the field, not only on Return.
- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (notification.object == _portField) [self portChanged:_portField];
}

@end

// --- Preferences page registration ---
namespace {
    class remote_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            return fb2k::wrapNSObject([[RemotePreferences alloc] init]);
        }
        const char* get_name() override { return "LAN Remote"; }
        GUID get_guid() override { return remote_config::guid_preferences_page; }
        GUID get_parent_guid() override { return preferences_page::guid_tools; }
    };
    FB2K_SERVICE_FACTORY(remote_preferences_page);
}
