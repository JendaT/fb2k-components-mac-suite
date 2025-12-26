//
//  Main.mm
//  foo_simplaylist_mac
//
//  Component registration and SDK integration
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"

#import "../UI/SimPlaylistView.h"
#import "../UI/SimPlaylistController.h"
#import "PlaylistCallbacks.h"

// Component version declaration with unified branding
JL_COMPONENT_ABOUT(
    "SimPlaylist",
    "1.0.0",
    "Simple playlist view for foobar2000 macOS\n\n"
    "Features:\n"
    "- Flat list view with virtual scrolling\n"
    "- Keyboard navigation\n"
    "- Selection sync with playlist manager"
);

VALIDATE_COMPONENT_FILENAME("foo_simplaylist.component");

// UI Element service registration (embeddable view)
namespace {
    static const GUID g_guid_simplaylist = {
        0xa1b2c3d4, 0xe5f6, 0x7890,
        {0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x90}
    };

    class simplaylist_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                SimPlaylistController* controller = [[SimPlaylistController alloc] init];
                return fb2k::wrapNSObject(controller);
            }
        }

        bool match_name(const char* name) override {
            return strcmp(name, "SimPlaylist") == 0 ||
                   strcmp(name, "simplaylist") == 0 ||
                   strcmp(name, "sim_playlist") == 0 ||
                   strcmp(name, "Simple Playlist") == 0;
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
