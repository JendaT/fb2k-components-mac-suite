//
//  Main.mm
//  foo_jl_wave_seekbar_mac
//
//  Component registration and SDK integration
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "ComponentInfo.h"
#include "../../../../shared/version.h"

#import "../UI/WaveformSeekbarView.h"
#import "../UI/WaveformSeekbarController.h"

// Component version declaration with unified branding
JL_COMPONENT_ABOUT(
    "Waveform Seekbar",
    WAVEFORM_VERSION,
    "Waveform seekbar for foobar2000 macOS\n\n"
    "Layout element: " JL_LAYOUT_NAME "\n"
    "Preferences: " JL_PREFERENCES_PATH "\n\n"
    "Features:\n"
    "- Full-track waveform with per-track loudness analysis (BS.1770)\n"
    "- Layered, Simple (two-tone, glow, heat) and Classic (solid, heat map, rainbow) styles\n"
    "- Stereo, mono or split (L up, R down) channels\n"
    "- Hover readout, loudness summary and clip markers\n"
    "- Time ruler and dB level scale\n"
    "- Click or drag to seek\n"
    "- Played part dimming with animated cursor effects, optionally synced to BPM\n"
    "- Phosphor and other color themes in Display P3, light/dark colors, glass background\n"
    "- Waveform cache with size and age limits\n"
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
            return JLMatchesLayoutName(name);
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
