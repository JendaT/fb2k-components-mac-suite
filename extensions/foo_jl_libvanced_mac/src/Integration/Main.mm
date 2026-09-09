//
//  Main.mm
//  foo_jl_libvanced
//
//  Component registration and SDK integration
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"

#import "../UI/LibVancedController.h"
#import "LibraryCallbacks.h"

JL_COMPONENT_ABOUT(
    "LibVanced",
    LIBVANCED_VERSION,
    "Advanced library browser for foobar2000 macOS\n\n"
    "Features:\n"
    "- Hierarchical tree view (Artist > Album > Track)\n"
    "- Configurable grouping patterns\n"
    "- Album art thumbnails\n"
    "- Drag & drop to playlists and queue\n"
    "- Context menu with queue/playlist actions\n"
    "- Keyboard shortcuts (Q to queue)\n"
    "- Search/filter with library search syntax\n"
    "- Cross-component interop (SimPlaylist, Queue Manager)"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_libvanced.component");

namespace {
    // {A3D7F2E1-8B4C-4F5A-9E6D-1C2B3A4D5E6F}
    static const GUID g_guid_libvanced = {
        0xA3D7F2E1, 0x8B4C, 0x4F5A,
        {0x9E, 0x6D, 0x1C, 0x2B, 0x3A, 0x4D, 0x5E, 0x6F}
    };

    class libvanced_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                LibVancedController* controller = [[LibVancedController alloc] init];
                return fb2k::wrapNSObject(controller);
            }
        }

        bool match_name(const char* name) override {
            return strcmp(name, "LibVanced") == 0 ||
                   strcmp(name, "libvanced") == 0 ||
                   strcmp(name, "lib_vanced") == 0 ||
                   strcmp(name, "Library Vanced") == 0 ||
                   strcmp(name, "foo_jl_libvanced") == 0 ||
                   strcmp(name, "jl_libvanced") == 0;
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("LibVanced");
        }

        GUID get_guid() override {
            return g_guid_libvanced;
        }
    };

    FB2K_SERVICE_FACTORY(libvanced_ui_element);
}

class libvanced_init : public initquit {
public:
    void on_init() override {
        LibVancedCallbackManager::instance().initCallbacks();
        console::info("[LibVanced] Component initialized");
    }

    void on_quit() override {
        LibVancedCallbackManager::instance().shutdownCallbacks();
        console::info("[LibVanced] Component shutting down");
    }
};

FB2K_SERVICE_FACTORY(libvanced_init);
