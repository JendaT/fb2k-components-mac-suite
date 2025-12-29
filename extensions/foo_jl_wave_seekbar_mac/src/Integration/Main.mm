//
//  Main.mm
//  foo_jl_wave_seekbar_mac
//
//  Component registration and SDK integration
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"

#import "../UI/WaveformSeekbarView.h"
#import "../UI/WaveformSeekbarController.h"

// Component version declaration with unified branding
JL_COMPONENT_ABOUT(
    "Waveform Seekbar",
    "1.1.0",
    "Waveform seekbar for foobar2000 macOS\n\n"
    "Features:\n"
    "- Complete waveform display\n"
    "- Click-to-seek functionality\n"
    "- Stereo and mono display modes\n"
    "- Dark mode support\n"
    "- Waveform caching\n"
    "- Lock width/height via context menu"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_wave_seekbar.component");

// UI Element service registration (embeddable view)
namespace {
    static const GUID g_guid_waveform_seekbar = {
        0x7A3F8B12, 0x4C5D, 0x6E7F,
        {0x8A, 0x9B, 0x0C, 0x1D, 0x2E, 0x3F, 0x4A, 0x5B}
    };

    class waveform_seekbar_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                WaveformSeekbarController* controller = [[WaveformSeekbarController alloc] init];
                return fb2k::wrapNSObject(controller);
            }
        }

        // Layout editor recognizes components by name - support all variations
        // This ensures backward compatibility when renaming components
        bool match_name(const char* name) override {
            return strcmp(name, "Waveform Seekbar") == 0 ||
                   strcmp(name, "waveform_seekbar") == 0 ||
                   strcmp(name, "waveform-seekbar") == 0 ||
                   strcmp(name, "waveform-seekbar-mac") == 0 ||
                   strcmp(name, "wave_seekbar") == 0 ||
                   // Legacy names (pre-jl prefix)
                   strcmp(name, "foo_wave_seekbar") == 0 ||
                   // New jl-prefixed names
                   strcmp(name, "foo_jl_wave_seekbar") == 0 ||
                   strcmp(name, "jl_wave_seekbar") == 0;
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("Waveform Seekbar");
        }

        GUID get_guid() override {
            return g_guid_waveform_seekbar;
        }
    };

    FB2K_SERVICE_FACTORY(waveform_seekbar_ui_element);
}

// Note: WaveformService initialization handled in PlaybackCallback.mm (waveform_init)
