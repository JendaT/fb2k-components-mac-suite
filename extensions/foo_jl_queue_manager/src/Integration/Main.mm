//
//  Main.mm
//  foo_jl_queue_manager
//
//  UI Element registration for Queue Manager component
//

#import "../UI/QueueManagerController.h"
#include <foobar2000/SDK/foobar2000.h>
#include "../../../../shared/version.h"

namespace {

// Component version declaration
DECLARE_COMPONENT_VERSION(
    "Queue Manager",
    QUEUE_MANAGER_VERSION,
    "Visual queue management for foobar2000 macOS.\n\n"
    "Features:\n"
    "- View and manage playback queue\n"
    "- Drag & drop reordering\n"
    "- Live updates\n"
    "- Configurable columns\n\n"
    "MIT License - https://github.com/jl/foo_jl_queue_manager"
);

// Unique GUID for this component
// Generated: use uuidgen command or online tool
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
        // Support multiple name variations for flexibility
        return strcmp(name, "Queue Manager") == 0 ||
               strcmp(name, "queue_manager") == 0 ||
               strcmp(name, "QueueManager") == 0 ||
               strcmp(name, "Queue manager") == 0 ||
               strcmp(name, "queue manager") == 0 ||
               strcmp(name, "foo_jl_queue_manager") == 0 ||
               strcmp(name, "jl_queue_manager") == 0 ||
               strcmp(name, "Queue") == 0;
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
