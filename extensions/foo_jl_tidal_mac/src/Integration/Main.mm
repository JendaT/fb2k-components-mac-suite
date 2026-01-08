//
//  Main.mm
//  foo_jl_tidal_mac
//
//  Component registration and initialization
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"
#include "../Core/TidalConfig.h"
#include "../Core/KeychainHelper.h"
#include "../Services/TidalAuthService.h"
#import "../UI/TidalPreferencesController.h"
#import "../UI/TidalBrowserController.h"

// Early static initialization check (runs when dylib loads)
namespace {
    struct EarlyInit {
        EarlyInit() {
            fprintf(stderr, "[Tidal] Binary loaded\n");
        }
    };
    static EarlyInit g_earlyInit;
}

// Component registration
JL_COMPONENT_ABOUT(
    "Tidal Integration",
    TIDAL_VERSION,
    "Stream Tidal content directly in your playlist.\n"
    "Supports HiFi and lossless audio quality with automatic DRM fallback."
);

// Validate bundle filename
VALIDATE_COMPONENT_FILENAME("foo_jl_tidal.component");

namespace {

// Initialization handler
class TidalInit : public initquit {
public:
    void on_init() override {
        using namespace tidal;

        // Load stored session from Keychain
        [[JLTidalAuthService shared] loadStoredSession];

        if ([[JLTidalAuthService shared] isAuthenticated]) {
            logInfo("Component loaded (authenticated)");
        } else {
            logInfo("Component loaded (not authenticated - configure in Preferences)");
        }
    }

    void on_quit() override {
        using namespace tidal;
        logInfo("Component unloading");
    }
};

FB2K_SERVICE_FACTORY(TidalInit);

} // anonymous namespace

// Preferences page registration
namespace {

// Preferences page GUID
// {A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
static const GUID g_guid_tidal_prefs =
    {0xa1b2c3d4, 0xe5f6, 0x7890, {0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x90}};

class tidal_preferences_page : public preferences_page {
public:
    service_ptr instantiate() override {
        @autoreleasepool {
            return fb2k::wrapNSObject(
                [[JLTidalPreferencesController alloc] init]
            );
        }
    }

    const char* get_name() override {
        return "Tidal";
    }

    GUID get_guid() override {
        return g_guid_tidal_prefs;
    }

    GUID get_parent_guid() override {
        return preferences_page::guid_tools;
    }
};

preferences_page_factory_t<tidal_preferences_page> g_tidal_prefs_factory;

} // anonymous namespace

// UI Element service registration (Tidal Browser panel)
namespace {

// {B3A4D5E6-F789-4A5B-8C1D-2E3F4A5B6C7D}
static const GUID g_guid_tidal_browser = {
    0xB3A4D5E6, 0xF789, 0x4A5B,
    {0x8C, 0x1D, 0x2E, 0x3F, 0x4A, 0x5B, 0x6C, 0x7D}
};

class tidal_browser_ui_element : public ui_element_mac {
public:
    service_ptr instantiate(service_ptr arg) override {
        @autoreleasepool {
            JLTidalBrowserController *controller = [[JLTidalBrowserController alloc] init];
            return fb2k::wrapNSObject(controller);
        }
    }

    bool match_name(const char* name) override {
        return strcmp(name, "Tidal Browser") == 0 ||
               strcmp(name, "tidal-browser") == 0 ||
               strcmp(name, "tidal_browser") == 0 ||
               strcmp(name, "TidalBrowser") == 0 ||
               strcmp(name, "foo_jl_tidal_browser") == 0;
    }

    fb2k::stringRef get_name() override {
        return fb2k::makeString("Tidal Browser");
    }

    GUID get_guid() override {
        return g_guid_tidal_browser;
    }
};

FB2K_SERVICE_FACTORY(tidal_browser_ui_element);

} // anonymous namespace
