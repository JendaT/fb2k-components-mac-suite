//
//  Main.mm
//  foo_jl_scrobble_mac
//
//  Component registration and entry point
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#import "../Core/ScrobbleConfig.h"
#import "../Services/ScrobbleService.h"
#import "../LastFm/LastFmAuth.h"
#import "../UI/ScrobblePreferencesController.h"
// Note: UI elements (toolbar widgets) are not supported in macOS SDK v2
// The ScrobbleStatusController is available for future use if API is added

// Component version declaration with unified branding
JL_COMPONENT_ABOUT(
    "Last.fm Scrobbler",
    "1.0.0",
    "Scrobbles played tracks to Last.fm.\n\n"
    "Features:\n"
    "- Automatic scrobbling after 50% or 4 minutes played\n"
    "- Now Playing notifications\n"
    "- Browser-based Last.fm authentication\n"
    "- Offline queue with automatic retry\n\n"
    "Based on foo_scrobble for Windows by gix.\n"
    "macOS port 2025."
);

// Validate bundle filename
VALIDATE_COMPONENT_FILENAME("foo_jl_scrobble.component");

// Component initialization handler
namespace {

class ScrobbleInitQuit : public initquit {
public:
    void on_init() override {
        @autoreleasepool {
            console::info("[Scrobble] Last.fm Scrobbler initializing...");

            // Log configuration status
            bool scrobblingEnabled = scrobble_config::isScrobblingEnabled();
            bool nowPlayingEnabled = scrobble_config::isNowPlayingEnabled();

            FB2K_console_formatter() << "[Scrobble] Scrobbling: "
                << (scrobblingEnabled ? "enabled" : "disabled")
                << ", Now Playing: "
                << (nowPlayingEnabled ? "enabled" : "disabled");

            // Start the scrobble service
            [[ScrobbleService shared] start];

            // Log auth status
            if ([[LastFmAuth shared] isAuthenticated]) {
                FB2K_console_formatter() << "[Scrobble] Authenticated as: "
                    << [[LastFmAuth shared] username].UTF8String;
            } else {
                console::info("[Scrobble] Not authenticated - use Preferences to sign in");
            }

            console::info("[Scrobble] Initialized successfully");
        }
    }

    void on_quit() override {
        @autoreleasepool {
            console::info("[Scrobble] Shutting down...");

            // Stop the service and save pending scrobbles
            [[ScrobbleService shared] stop];

            console::info("[Scrobble] Shut down complete");
        }
    }
};

FB2K_SERVICE_FACTORY(ScrobbleInitQuit);

} // anonymous namespace

// Preferences page registration
namespace {
    // Preferences page GUID
    // {7A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D}
    static const GUID g_guid_prefs =
        {0x7a1b2c3d, 0x4e5f, 0x6a7b, {0x8c, 0x9d, 0x0e, 0x1f, 0x2a, 0x3b, 0x4c, 0x5d}};

    class scrobble_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            @autoreleasepool {
                return fb2k::wrapNSObject(
                    [[ScrobblePreferencesController alloc] init]
                );
            }
        }

        const char* get_name() override {
            return "Last.fm Scrobbler";
        }

        GUID get_guid() override {
            return g_guid_prefs;
        }

        GUID get_parent_guid() override {
            return preferences_page::guid_tools;
        }
    };

    preferences_page_factory_t<scrobble_preferences_page> g_prefs_factory;
}

// UI Element registration
// Note: ui_element_mac is not available in macOS SDK v2
// Status widget would require API support from foobar2000
// For now, status is shown in the Preferences page
