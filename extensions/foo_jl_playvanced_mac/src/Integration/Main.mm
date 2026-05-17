#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"

#import "../UI/PlayVancedController.h"
#import "../Core/ArtworkFetcher.h"

JL_COMPONENT_ABOUT(
    "PlayVanced",
    PLAYVANCED_VERSION,
    "Now Playing panel for foobar2000 macOS\n\n"
    "Features:\n"
    "- Large album art with rounded corners\n"
    "- Track metadata display (title, artist, album, genre)\n"
    "- Progress bar with elapsed/remaining time\n"
    "- Selection-aware: shows selected track when not playing\n"
    "- Technical info (codec, bitrate, sample rate)\n"
    "- Dark mode and glass effect support"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_playvanced.component");

namespace {
    // {D7A3E5B1-4F8C-2D6E-9B1A-3C5D7E8F0A2B}
    static const GUID g_guid_playvanced = {
        0xD7A3E5B1, 0x4F8C, 0x2D6E,
        {0x9B, 0x1A, 0x3C, 0x5D, 0x7E, 0x8F, 0x0A, 0x2B}
    };

    class playvanced_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                PlayVancedController* controller = [[PlayVancedController alloc] init];
                PlayVancedCallbackManager::instance().registerController(controller);
                return fb2k::wrapNSObject(controller);
            }
        }

        bool match_name(const char* name) override {
            return strcmp(name, "PlayVanced") == 0 ||
                   strcmp(name, "playvanced") == 0 ||
                   strcmp(name, "play_vanced") == 0 ||
                   strcmp(name, "NowPlaying") == 0 ||
                   strcmp(name, "nowplaying") == 0 ||
                   strcmp(name, "now_playing") == 0 ||
                   strcmp(name, "foo_jl_playvanced") == 0 ||
                   strcmp(name, "jl_playvanced") == 0;
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("PlayVanced");
        }

        GUID get_guid() override {
            return g_guid_playvanced;
        }
    };

    FB2K_SERVICE_FACTORY(playvanced_ui_element);
}

class playvanced_init : public initquit {
public:
    void on_init() override {
        console::info("[PlayVanced] Component initialized");
    }

    void on_quit() override {
    }
};

FB2K_SERVICE_FACTORY(playvanced_init);
