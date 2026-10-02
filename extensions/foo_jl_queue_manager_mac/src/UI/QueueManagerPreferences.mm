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
#import "../Integration/StopAfterQueue.h"
#import "../../../../shared/PreferencesCommon.h"

// Flipped view for top-to-bottom layout (unique class name per extension)
@interface QueueManagerFlippedView : NSView
@end
@implementation QueueManagerFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface QueueManagerPreferences () {
    NSButton *_transparentBackgroundCheckbox;
    NSButton *_persistQueueCheckbox;
    NSButton *_stopAfterQueueCheckbox;
    NSButton *_stopAfterQueueOnceCheckbox;
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

- (void)viewWillAppear {
    [super viewWillAppear];
    // Menus can change settings while this page is not visible
    [self loadSettings];
}

- (void)loadView {
    QueueManagerFlippedView *view = [[QueueManagerFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 450, 320)];
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
    y += 28;

    // Behavior section header
    NSTextField *behaviorHeader = JLCreateSectionHeader(@"Behavior");
    behaviorHeader.frame = NSMakeRect(labelX, y, 200, 17);
    [self.view addSubview:behaviorHeader];
    y += 22;

    // Persist queue checkbox
    _persistQueueCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + JLPrefsIndent, y, 350, 20)];
    _persistQueueCheckbox.buttonType = NSButtonTypeSwitch;
    _persistQueueCheckbox.title = @"Restore queue after restart";
    [_persistQueueCheckbox setTarget:self];
    [_persistQueueCheckbox setAction:@selector(persistQueueChanged:)];
    [self.view addSubview:_persistQueueCheckbox];
    y += 24;

    NSTextField *persistHelper = JLCreateHelperText(@"Queued tracks are saved on quit and re-added on launch");
    persistHelper.frame = NSMakeRect(labelX + JLPrefsIndent + 20, y, 350, 14);
    [self.view addSubview:persistHelper];
    y += 24;

    // Stop after queue checkbox
    _stopAfterQueueCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + JLPrefsIndent, y, 350, 20)];
    _stopAfterQueueCheckbox.buttonType = NSButtonTypeSwitch;
    _stopAfterQueueCheckbox.title = @"Stop after queue";
    [_stopAfterQueueCheckbox setTarget:self];
    [_stopAfterQueueCheckbox setAction:@selector(stopAfterQueueChanged:)];
    [self.view addSubview:_stopAfterQueueCheckbox];
    y += 24;

    NSTextField *stopHelper = JLCreateHelperText(@"Playback stops when the last queued track finishes");
    stopHelper.frame = NSMakeRect(labelX + JLPrefsIndent + 20, y, 350, 14);
    [self.view addSubview:stopHelper];
    y += 20;

    // Only-once sub-option (enabled only while stop after queue is on)
    _stopAfterQueueOnceCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + JLPrefsIndent + 20, y, 330, 20)];
    _stopAfterQueueOnceCheckbox.buttonType = NSButtonTypeSwitch;
    _stopAfterQueueOnceCheckbox.title = @"Turn off after it stops playback once";
    [_stopAfterQueueOnceCheckbox setTarget:self];
    [_stopAfterQueueOnceCheckbox setAction:@selector(stopAfterQueueOnceChanged:)];
    [self.view addSubview:_stopAfterQueueOnceCheckbox];
}

- (void)loadSettings {
    using namespace queue_config;

    _transparentBackgroundCheckbox.state = getConfigBool(
        kKeyTransparentBackground,
        kDefaultTransparentBackground) ? NSControlStateValueOn : NSControlStateValueOff;

    _persistQueueCheckbox.state = getConfigBool(
        kKeyPersistQueue,
        kDefaultPersistQueue) ? NSControlStateValueOn : NSControlStateValueOff;

    // Also toggled from the Playback menu and the Queue Manager context menu
    _stopAfterQueueCheckbox.state = stop_after_queue::isEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    _stopAfterQueueOnceCheckbox.state = stop_after_queue::isOnlyOnce() ? NSControlStateValueOn : NSControlStateValueOff;
    _stopAfterQueueOnceCheckbox.enabled = stop_after_queue::isEnabled();
}

- (void)transparentBackgroundChanged:(id)sender {
    using namespace queue_config;
    setConfigBool(kKeyTransparentBackground, _transparentBackgroundCheckbox.state == NSControlStateValueOn);
}

- (void)persistQueueChanged:(id)sender {
    using namespace queue_config;
    setConfigBool(kKeyPersistQueue, _persistQueueCheckbox.state == NSControlStateValueOn);
}

- (void)stopAfterQueueChanged:(id)sender {
    BOOL on = _stopAfterQueueCheckbox.state == NSControlStateValueOn;
    stop_after_queue::setEnabled(on);
    _stopAfterQueueOnceCheckbox.enabled = on;
}

- (void)stopAfterQueueOnceChanged:(id)sender {
    stop_after_queue::setOnlyOnce(_stopAfterQueueOnceCheckbox.state == NSControlStateValueOn);
}

@end

// Preferences page registration
namespace {
    // FROZEN: see Main.mm. Hand-typed but verified unique across the suite;
    // changing a registered page GUID gains nothing and risks stale state.
    static const GUID guid_queue_manager_preferences = {
        0x7F3A2B1C, 0x4D5E, 0x6F78,
        {0x9A, 0xBC, 0xDE, 0xF0, 0x12, 0x34, 0x56, 0x78}
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
