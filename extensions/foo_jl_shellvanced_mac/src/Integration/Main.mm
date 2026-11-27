#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"

#import "../UI/ShellVancedController.h"

JL_COMPONENT_ABOUT(
    "ShellVanced",
    SHELLVANCED_VERSION,
    "Streaming-style shell for foobar2000 macOS\n\n"
    "Hosts other components (AlbumViewVanced, SimPlaylist) inside a single\n"
    "layout element. Early work in progress."
);

VALIDATE_COMPONENT_FILENAME("foo_jl_shellvanced.component");

// {66531224-87ED-4A8F-A869-C99A43D6B1B4}
extern const GUID g_guid_shellvanced;
const GUID g_guid_shellvanced = {
    0x66531224, 0x87ED, 0x4A8F,
    {0xA8, 0x69, 0xC9, 0x9A, 0x43, 0xD6, 0xB1, 0xB4}
};

namespace {
    class shellvanced_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                ShellVancedController* controller = [[ShellVancedController alloc] init];
                return fb2k::wrapNSObject(controller);
            }
        }

        bool match_name(const char* name) override {
            return strcmp(name, "ShellVanced") == 0 ||
                   strcmp(name, "shellvanced") == 0 ||
                   strcmp(name, "vanced_shell") == 0;
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("ShellVanced");
        }

        GUID get_guid() override {
            return g_guid_shellvanced;
        }
    };

    FB2K_SERVICE_FACTORY(shellvanced_ui_element);
}

class shellvanced_init : public initquit {
public:
    void on_init() override {
        console::info("[ShellVanced] Component initialized");
    }

    void on_quit() override {
    }
};

FB2K_SERVICE_FACTORY(shellvanced_init);
