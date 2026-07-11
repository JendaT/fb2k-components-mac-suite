//
//  QueueManagerPreferences.mm
//  foo_jl_queue_manager
//
//  Preferences page for Queue Manager configuration
//

#import "QueueManagerPreferences.h"
#include "../fb2k_sdk.h"
#include "../Core/QueueConfig.h"
#include "../Core/ConfigHelper.h"
#import "../../../../shared/PreferencesCommon.h"

// Flipped view for top-to-bottom layout (unique class name per extension)
@interface QueueManagerFlippedView : NSView
@end
@implementation QueueManagerFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface QueueManagerPreferences () {
    NSButton *_transparentBackgroundCheckbox;
}
@end

@implementation QueueManagerPreferences

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    return self;
}

- (NSString *)preferencesTitle {
    return @"Queue Manager";
}

- (void)loadView {
    QueueManagerFlippedView *view = [[QueueManagerFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 450, 150)];
    self.view = view;

    [self buildUI];
    [self loadSettings];
}

- (void)buildUI {
    CGFloat y = 10;  // Start from top (flipped coordinate system)
    CGFloat labelX = JLPrefsLeftMargin;

    // Page title (non-bold, matches foobar2000 style)
    NSTextField *title = JLCreatePreferencesTitle(@"Queue Manager");
    title.frame = NSMakeRect(labelX, y, 400, 20);
    [self.view addSubview:title];
    y += 28;

    // Display section header
    NSTextField *displayHeader = JLCreateSectionHeader(@"Appearance");
    displayHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:displayHeader];
    y += 22;

    // Transparent background checkbox
    _transparentBackgroundCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + JLPrefsIndent, y, 350, 20)];
    _transparentBackgroundCheckbox.buttonType = NSButtonTypeSwitch;
    _transparentBackgroundCheckbox.title = @"Transparent background (glass effect)";
    [_transparentBackgroundCheckbox setTarget:self];
    [_transparentBackgroundCheckbox setAction:@selector(transparentBackgroundChanged:)];
    [self.view addSubview:_transparentBackgroundCheckbox];
    y += 24;

    // Helper text
    NSTextField *helperText = JLCreateHelperText(@"Requires restart to take effect");
    helperText.frame = NSMakeRect(labelX + JLPrefsIndent + 20, y, 300, 14);
    [self.view addSubview:helperText];
}

- (void)loadSettings {
    using namespace queue_config;

    _transparentBackgroundCheckbox.state = getConfigBool(
        kKeyTransparentBackground,
        kDefaultTransparentBackground) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)transparentBackgroundChanged:(id)sender {
    using namespace queue_config;
    setConfigBool(kKeyTransparentBackground, _transparentBackgroundCheckbox.state == NSControlStateValueOn);
}

@end

// Preferences page registration
namespace {
    // Unique GUID for Queue Manager preferences
    // (uuidgen: 12496D9A-A3A5-43FF-802E-4B7114C9E68A)
    static const GUID guid_queue_manager_preferences = {
        0x12496d9a, 0xa3a5, 0x43ff,
        {0x80, 0x2e, 0x4b, 0x71, 0x14, 0xc9, 0xe6, 0x8a}
    };

    class queue_manager_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            return fb2k::wrapNSObject([[QueueManagerPreferences alloc] init]);
        }

        const char* get_name() override {
            return "Queue Manager";
        }

        GUID get_guid() override {
            return guid_queue_manager_preferences;
        }

        GUID get_parent_guid() override {
            return preferences_page::guid_display;
        }
    };

    FB2K_SERVICE_FACTORY(queue_manager_preferences_page);
}
