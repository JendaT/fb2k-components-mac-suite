//
//  Main.mm
//  foo_plorg_mac
//
//  Component registration and SDK integration
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"

#import "../UI/PlaylistOrganizerController.h"
#import "../UI/OrganizerPreferencesController.h"

// Component version declaration with unified branding
JL_COMPONENT_ABOUT(
    "Playlist Organizer",
    "1.0.0",
    "Playlist Organizer for foobar2000 macOS\n\n"
    "Features:\n"
    "- Hierarchical playlist organization with folders\n"
    "- Drag and drop reordering\n"
    "- Customizable node display formatting\n"
    "- Automatic sync with playlist changes\n\n"
    "Based on foo_plorg by Holger Stenger."
);

VALIDATE_COMPONENT_FILENAME("foo_plorg.component");

// UI Element service registration
namespace {
    // {A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
    static const GUID g_guid_playlist_organizer = {
        0xA1B2C3D4, 0xE5F6, 0x7890,
        {0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x90}
    };

    class playlist_organizer_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                console::info("[Plorg] UI element instantiate called");
                PlaylistOrganizerController* controller = [[PlaylistOrganizerController alloc] init];
                if (controller) {
                    console::info("[Plorg] Controller created successfully");
                } else {
                    console::error("[Plorg] Failed to create controller");
                }
                return fb2k::wrapNSObject(controller);
            }
        }

        bool match_name(const char* name) override {
            return strcmp(name, "Playlist Organizer") == 0 ||
                   strcmp(name, "playlist_organizer") == 0 ||
                   strcmp(name, "playlist-organizer") == 0 ||
                   strcmp(name, "plorg") == 0 ||
                   strcmp(name, "foo_plorg") == 0;
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("Playlist Organizer");
        }

        GUID get_guid() override {
            return g_guid_playlist_organizer;
        }
    };

    FB2K_SERVICE_FACTORY(playlist_organizer_ui_element);

    // Preferences page GUID
    // {B2C3D4E5-F678-9012-BCDE-F12345678901}
    static const GUID g_guid_plorg_preferences = {
        0xB2C3D4E5, 0xF678, 0x9012,
        {0xBC, 0xDE, 0xF1, 0x23, 0x45, 0x67, 0x89, 0x01}
    };

    class plorg_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            @autoreleasepool {
                OrganizerPreferencesController* controller = [[OrganizerPreferencesController alloc] init];
                return fb2k::wrapNSObject(controller);
            }
        }

        const char* get_name() override {
            return "Playlist Organizer";
        }

        GUID get_guid() override {
            return g_guid_plorg_preferences;
        }

        GUID get_parent_guid() override {
            return preferences_page::guid_display;
        }
    };

    preferences_page_factory_t<plorg_preferences_page> g_prefs_factory;
}
