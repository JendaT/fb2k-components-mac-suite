//
//  Main.mm
//  foo_jl_spectrum_mac
//
//  Component registration and SDK integration.
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"

#import "../UI/SpectrumController.h"

JL_COMPONENT_ABOUT(
    "Spectrum Analyzer",
    SPECTRUM_VERSION,
    "Real-time spectrum analyzer for foobar2000 macOS\n\n"
    "Features:\n"
    "- Live FFT frequency bars from the playback stream\n"
    "- Logarithmic or linear frequency scale\n"
    "- Adjustable bar count, FFT size, and smoothing\n"
    "- Falling peak caps\n"
    "- Solid / gradient / spectrum bar styles\n"
    "- Light and dark mode colors\n"
    "- Glass background (translucent blur)"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_spectrum.component");

// UI Element service registration (embeddable view)
namespace {
    static const GUID g_guid_spectrum_ui_element = {
        0x6E1B4A83, 0x2C9F, 0x4D51,
        {0xB7, 0x3A, 0x0F, 0x82, 0x64, 0x11, 0x9C, 0xE0}
    };

    class spectrum_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                SpectrumController* controller = [[SpectrumController alloc] init];
                return fb2k::wrapNSObject(controller);
            }
        }

        bool match_name(const char* name) override {
            return strcmp(name, "Spectrum Analyzer") == 0 ||
                   strcmp(name, "spectrum_analyzer") == 0 ||
                   strcmp(name, "spectrum") == 0 ||
                   strcmp(name, "foo_jl_spectrum") == 0 ||
                   strcmp(name, "jl_spectrum") == 0;
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("Spectrum Analyzer");
        }

        GUID get_guid() override {
            return g_guid_spectrum_ui_element;
        }
    };

    FB2K_SERVICE_FACTORY(spectrum_ui_element);
}
