#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"

#import "../UI/AlbumViewVancedController.h"
#import "AlbumViewVancedCallbacks.h"

JL_COMPONENT_ABOUT(
    "AlbumViewVanced",
    ALBUMVIEWVANCED_VERSION,
    "Album grid library browser for foobar2000 macOS\n\n"
    "Features:\n"
    "- Album grid with cover art thumbnails\n"
    "- In-place track list expansion\n"
    "- Search/filter with library search syntax\n"
    "- Drag & drop to playlists and queue\n"
    "- Context menu with playlist/queue actions\n"
    "- Keyboard shortcuts (Q to queue, Enter to play)\n"
    "- Dark mode support"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_albumviewvanced.component");

namespace {
    // {B4E8F3A2-9C5D-4E6B-AF7E-2D3C4B5A6E7F}
    static const GUID g_guid_albumviewvanced = {
        0xB4E8F3A2, 0x9C5D, 0x4E6B,
        {0xAF, 0x7E, 0x2D, 0x3C, 0x4B, 0x5A, 0x6E, 0x7F}
    };

    class albumviewvanced_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                AlbumViewVancedController* controller = [[AlbumViewVancedController alloc] init];
                AlbumViewVancedCallbackManager::instance().registerController(controller);
                return fb2k::wrapNSObject(controller);
            }
        }

        bool match_name(const char* name) override {
            return strcmp(name, "AlbumViewVanced") == 0 ||
                   strcmp(name, "albumviewvanced") == 0 ||
                   strcmp(name, "album_view_vanced") == 0;
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("AlbumViewVanced");
        }

        GUID get_guid() override {
            return g_guid_albumviewvanced;
        }
    };

    FB2K_SERVICE_FACTORY(albumviewvanced_ui_element);
}

class albumviewvanced_init : public initquit {
public:
    void on_init() override {
        console::info("[AlbumViewVanced] Component initialized");
    }

    void on_quit() override {
        console::info("[AlbumViewVanced] Component shutting down");
    }
};

FB2K_SERVICE_FACTORY(albumviewvanced_init);
