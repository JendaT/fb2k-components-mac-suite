//
//  Main.mm
//  foo_jl_spectrogram_mac
//
//  Component registration and SDK integration.
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"

#import "../UI/SpectrogramController.h"

JL_COMPONENT_ABOUT(
    "Spectrogram",
    SPECTROGRAM_VERSION,
    "Scrolling spectrogram for foobar2000 macOS\n\n"
    "Features:\n"
    "- Frequency content over time from the playback stream\n"
    "- Reassigned analysis: thin tonal lines and sharp transients together\n"
    "- Logarithmic, mel, or linear frequency scale\n"
    "- Colormaps, including ramps matching the Spectrum Analyzer themes, with a dB color scale\n"
    "- Adjustable level range, slope, and scroll speed\n"
    "- Mid, left, right, or side channel\n"
    "- Click-and-hold frequency and note readout"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_spectrogram.component");

// UI Element service registration (embeddable view)
namespace {
    static const GUID g_guid_spectrogram_ui_element = {
        0x3D7F92B6, 0x1E48, 0x4C0A,
        {0xA6, 0x5C, 0x2B, 0x91, 0xE4, 0x07, 0xD3, 0x58}
    };

    class spectrogram_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                SpectrogramController* controller = [[SpectrogramController alloc] init];
                return fb2k::wrapNSObject(controller);
            }
        }

        bool match_name(const char* name) override {
            return strcmp(name, "Spectrogram") == 0 ||
                   strcmp(name, "spectrogram") == 0 ||
                   strcmp(name, "foo_jl_spectrogram") == 0 ||
                   strcmp(name, "jl_spectrogram") == 0;
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("Spectrogram");
        }

        GUID get_guid() override {
            return g_guid_spectrogram_ui_element;
        }
    };

    FB2K_SERVICE_FACTORY(spectrogram_ui_element);
}
