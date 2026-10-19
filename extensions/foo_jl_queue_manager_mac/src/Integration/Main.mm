//
//  Main.mm
//  foo_jl_queue_manager
//
//  UI Element registration for Queue Manager component
//

#import "../UI/QueueManagerController.h"
#include <foobar2000/SDK/foobar2000.h>
#include "../../../../shared/version.h"
#include "../../../../shared/common_about.h"
#include "ComponentInfo.h"

namespace {

// Component version declaration
JL_COMPONENT_ABOUT(
    "Queue Manager",
    QUEUE_MANAGER_VERSION,
    "Visual queue management for foobar2000 macOS\n\n"
    "Layout element: " JL_LAYOUT_NAME "\n"
    "Preferences: " JL_PREFERENCES_PATH "\n\n"
    "Features:\n"
    "- View, play and remove queued tracks, updated live\n"
    "- Drag & drop reordering, several rows at once\n"
    "- Drag tracks in from SimPlaylist\n"
    "- Queue restored after restart\n"
    "- Stop After Queue in the Playback menu and right-click menu\n"
    "- Optional one-shot mode for Stop After Queue"
);

// FROZEN: foobar2000 persists saved layouts by element GUID, so changing
// this makes the element vanish from existing users' layouts. Hand-typed
// rather than uuidgen output, but verified unique across the suite.
static const GUID g_guid_queue_manager = {
    0x8a1b2c3d, 0x4e5f, 0x6a7b, { 0x8c, 0x9d, 0x0e, 0x1f, 0x2a, 0x3b, 0x4c, 0x5d }
};

// UI Element implementation
class queue_manager_ui_element : public ui_element_mac {
public:
    // Create instance of the controller
    service_ptr instantiate(service_ptr arg) override {
        @autoreleasepool {
            QueueManagerController* controller = [[QueueManagerController alloc] init];
            return fb2k::wrapNSObject(controller);
        }
    }

    // Match by name for layout editor
    bool match_name(const char* name) override {
        return JLMatchesLayoutName(name);
    }

    // Display name in layout editor
    fb2k::stringRef get_name() override {
        return fb2k::makeString("Queue Manager");
    }

    // Unique GUID
    GUID get_guid() override {
        return g_guid_queue_manager;
    }
};

FB2K_SERVICE_FACTORY(queue_manager_ui_element);

} // namespace
