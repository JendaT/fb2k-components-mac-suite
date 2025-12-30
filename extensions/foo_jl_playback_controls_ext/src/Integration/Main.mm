//
//  Main.mm
//  foo_jl_playback_controls_ext
//
//  Component registration and entry point
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"
#import "../Core/PlaybackControlsConfig.h"
#import "../UI/PlaybackControlsController.h"

// Component version declaration with unified branding
JL_COMPONENT_ABOUT(
    "Playback Controls",
    PLAYBACK_CONTROLS_VERSION,
    "Customizable playback controls panel for foobar2000.\n\n"
    "Features:\n"
    "- Transport buttons (play/pause, stop, previous, next)\n"
    "- Volume slider with mute toggle\n"
    "- Configurable track info display\n"
    "- Click track info to navigate to playing item\n"
    "- Drag-to-reorder editing mode\n"
    "- Compact and full display modes\n\n"
    "Use 'Playback Controls' in layout editor to add this element."
);

// Validate bundle filename
VALIDATE_COMPONENT_FILENAME("foo_jl_playback_controls.component");

// Component initialization handler
namespace {

class PlaybackControlsInitQuit : public initquit {
public:
    void on_init() override {
        console::info("[PlaybackControls] Initializing...");

        // Log configuration
        std::string topFormat = playback_controls_config::getTopRowFormat();
        std::string bottomFormat = playback_controls_config::getBottomRowFormat();

        FB2K_console_formatter() << "[PlaybackControls] Top format: " << topFormat.c_str();
        FB2K_console_formatter() << "[PlaybackControls] Bottom format: " << bottomFormat.c_str();

        console::info("[PlaybackControls] Initialized successfully");
    }

    void on_quit() override {
        console::info("[PlaybackControls] Shutting down...");
    }
};

FB2K_SERVICE_FACTORY(PlaybackControlsInitQuit);

} // anonymous namespace

// UI Element registration
namespace {

// UI Element GUID
// {A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
static const GUID g_guid_playback_controls =
    {0xa1b2c3d4, 0xe5f6, 0x7890, {0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x90}};

class playback_controls_ui_element : public ui_element_mac {
public:
    service_ptr instantiate(service_ptr arg) override {
        @autoreleasepool {
            NSDictionary<NSString*, NSString*>* params = nil;

            if (arg.is_valid()) {
                id obj = fb2k::unwrapNSObject(arg);
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    params = (NSDictionary<NSString*, NSString*>*)obj;
                }
            }

            PlaybackControlsController* controller =
                [[PlaybackControlsController alloc] initWithParameters:params];
            return fb2k::wrapNSObject(controller);
        }
    }

    bool match_name(const char* name) override {
        return strcmp(name, "Playback Controls") == 0 ||
               strcmp(name, "playback_controls") == 0 ||
               strcmp(name, "transport") == 0 ||
               strcmp(name, "transport_controls") == 0 ||
               strcmp(name, "PlaybackControls") == 0;
    }

    fb2k::stringRef get_name() override {
        return fb2k::makeString("Playback Controls");
    }

    GUID get_guid() override {
        return g_guid_playback_controls;
    }
};

FB2K_SERVICE_FACTORY(playback_controls_ui_element);

} // anonymous namespace

// Preferences page registration
namespace {

// Preferences GUID
// {B2C3D4E5-F678-90AB-CDEF-123456789012}
static const GUID g_guid_prefs =
    {0xb2c3d4e5, 0xf678, 0x90ab, {0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12}};

// Forward declaration - preferences controller would be implemented separately
// For now, we'll skip the preferences page as settings can be changed via context menu

/*
class playback_controls_preferences : public preferences_page {
public:
    service_ptr instantiate() override {
        @autoreleasepool {
            // Would return PlaybackControlsPreferencesController
            return service_ptr();
        }
    }

    const char* get_name() override {
        return "Playback Controls";
    }

    GUID get_guid() override {
        return g_guid_prefs;
    }

    GUID get_parent_guid() override {
        return preferences_page::guid_display;
    }
};

preferences_page_factory_t<playback_controls_preferences> g_prefs_factory;
*/

} // anonymous namespace
