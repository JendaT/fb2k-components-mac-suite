//
//  Main.mm
//  foo_jl_simplaylist_mac
//
//  Component registration and SDK integration
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "ComponentInfo.h"
#include "../../../../shared/version.h"

#import "../UI/SimPlaylistView.h"
#import "../UI/SimPlaylistController.h"
#import "PlaylistCallbacks.h"

// Component version declaration with unified branding
JL_COMPONENT_ABOUT(
    "SimPlaylist",
    SIMPLAYLIST_VERSION,
    "Simple playlist view for foobar2000 macOS\n\n"
    "Layout element: " JL_LAYOUT_NAME "\n"
    "Preferences: " JL_PREFERENCES_PATH "\n\n"
    "Features:\n"
    "- Album grouping with cover art, configurable patterns\n"
    "- Four header display styles, disc subgroups\n"
    "- Built-in, component-provided and custom columns\n"
    "- Queue column; Q queues the selected tracks\n"
    "- Drag & drop reordering, drops from Finder and album list\n"
    "- Sort and Remove in the context menu, undo/redo\n"
    "- Remembers the scroll position of each playlist\n"
    "- Now playing highlight and Focus Playing Now\n"
    "- Keeps playback in its playlist while browsing the library"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_simplaylist.component");

// UI Element service registration (embeddable view)
namespace {
    // {8FE5C4B4-619D-4D89-8567-1D96C32E2162}
    static const GUID g_guid_simplaylist = {
        0x8FE5C4B4, 0x619D, 0x4D89,
        {0x85, 0x67, 0x1D, 0x96, 0xC3, 0x2E, 0x21, 0x62}
    };

    class simplaylist_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                SimPlaylistController* controller = [[SimPlaylistController alloc] init];
                return fb2k::wrapNSObject(controller);
            }
        }

        // Layout editor recognizes components by name - support all variations
        // This ensures backward compatibility when renaming components
        bool match_name(const char* name) override {
            return JLMatchesLayoutName(name);
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("SimPlaylist");
        }

        GUID get_guid() override {
            return g_guid_simplaylist;
        }
    };

    FB2K_SERVICE_FACTORY(simplaylist_ui_element);
}

// Initialization handler
namespace {

class simplaylist_init : public initquit {
public:
    void on_init() override {
        SimPlaylistCallbackManager::instance().initCallbacks();
        console::info("[SimPlaylist] Component initialized");
    }

    void on_quit() override {
        SimPlaylistCallbackManager::instance().shutdownCallbacks();
        console::info("[SimPlaylist] Component shutting down");
    }
};

FB2K_SERVICE_FACTORY(simplaylist_init);

}  // namespace
