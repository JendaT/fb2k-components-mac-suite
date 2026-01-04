//
//  Main.mm
//  foo_jl_cloud_streamer_mac
//
//  Component registration and initialization
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"
#include "../Core/CloudConfig.h"
#include "../Core/StreamCache.h"
#include "../Core/MetadataCache.h"
#include "../Core/ThumbnailCache.h"
#include "../Services/StreamResolver.h"
#import "../UI/CloudPreferencesController.h"
#import "../UI/CloudBrowserController.h"

// Early static initialization check (runs when dylib loads)
namespace {
    struct EarlyInit {
        EarlyInit() {
            // This prints when the dylib is loaded, before any services are registered
            fprintf(stderr, "[Cloud Streamer] Binary loaded\n");
        }
    };
    static EarlyInit g_earlyInit;
}

// Component registration
JL_COMPONENT_ABOUT(
    "Cloud Streamer",
    CLOUD_STREAMER_VERSION,
    "Stream Mixcloud and SoundCloud content directly in your playlist.\n"
    "Requires yt-dlp to be installed (via Homebrew)."
);

// Validate bundle filename
VALIDATE_COMPONENT_FILENAME("foo_jl_cloud_streamer.component");

namespace {

// Initialization handler
class CloudStreamerInit : public initquit {
public:
    void on_init() override {
        using namespace cloud_streamer;

        // Initialize caches
        MetadataCache::shared().initialize();
        ThumbnailCache::shared().initialize();

        // Initialize resolver
        StreamResolver::shared().initialize();

        // Detect yt-dlp if not configured
        std::string ytdlpPath = CloudConfig::getYtDlpPath();
        if (ytdlpPath.empty()) {
            std::string detected = CloudConfig::detectYtDlpPath();
            if (!detected.empty()) {
                CloudConfig::setYtDlpPath(detected);
                logDebug("Auto-detected yt-dlp at: " + detected);
            }
        }

        console::info("[Cloud Streamer] Component loaded");
    }

    void on_quit() override {
        using namespace cloud_streamer;

        // Shutdown services
        StreamResolver::shared().shutdown();

        // Shutdown caches (saves metadata to disk)
        ThumbnailCache::shared().shutdown();
        MetadataCache::shared().shutdown();
        StreamCache::shared().shutdown();

        console::info("[Cloud Streamer] Component unloading");
    }
};

FB2K_SERVICE_FACTORY(CloudStreamerInit);

} // anonymous namespace

// Preferences page registration
namespace {

// Preferences page GUID
// {C4D5E6F7-8A9B-0C1D-2E3F-4A5B6C7D8E9F}
static const GUID g_guid_prefs =
    {0xc4d5e6f7, 0x8a9b, 0x0c1d, {0x2e, 0x3f, 0x4a, 0x5b, 0x6c, 0x7d, 0x8e, 0x9f}};

class cloud_streamer_preferences_page : public preferences_page {
public:
    service_ptr instantiate() override {
        @autoreleasepool {
            return fb2k::wrapNSObject(
                [[CloudPreferencesController alloc] init]
            );
        }
    }

    const char* get_name() override {
        return "Cloud Streamer";
    }

    GUID get_guid() override {
        return g_guid_prefs;
    }

    GUID get_parent_guid() override {
        return preferences_page::guid_tools;
    }
};

preferences_page_factory_t<cloud_streamer_preferences_page> g_prefs_factory;

} // anonymous namespace

// Cloud Browser UI Element registration
namespace {

// Cloud Browser GUID
// {86DBA3F9-AD73-47E7-829F-0D2C5B9E0D01}
static const GUID g_guid_cloud_browser = {
    0x86dba3f9, 0xad73, 0x47e7, { 0x82, 0x9f, 0x0d, 0x2c, 0x5b, 0x9e, 0x0d, 0x01 }
};

class cloud_browser_ui_element : public ui_element_mac {
public:
    // Create instance of the controller
    service_ptr instantiate(service_ptr arg) override {
        @autoreleasepool {
            CloudBrowserController* controller = [[CloudBrowserController alloc] init];
            return fb2k::wrapNSObject(controller);
        }
    }

    // Match by name for layout editor
    bool match_name(const char* name) override {
        return strcmp(name, "Cloud Browser") == 0 ||
               strcmp(name, "cloud_browser") == 0 ||
               strcmp(name, "CloudBrowser") == 0 ||
               strcmp(name, "Cloud browser") == 0 ||
               strcmp(name, "cloud browser") == 0 ||
               strcmp(name, "foo_jl_cloud_browser") == 0 ||
               strcmp(name, "jl_cloud_browser") == 0;
    }

    // Display name in layout editor
    fb2k::stringRef get_name() override {
        return fb2k::makeString("Cloud Browser");
    }

    // Unique GUID
    GUID get_guid() override {
        return g_guid_cloud_browser;
    }
};

FB2K_SERVICE_FACTORY(cloud_browser_ui_element);

} // anonymous namespace
