//
//  Main.mm
//  foo_jl_spectrum_mac
//
//  Component registration and SDK integration.
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "ComponentInfo.h"
#include "../../../../shared/version.h"

#import "../UI/SpectrumController.h"

JL_COMPONENT_ABOUT_BY(
    "Spectrum Analyzer",
    SPECTRUM_VERSION,
    "Scannou",
    "Real-time spectrum analyzer for foobar2000 macOS\n\n"
    "Layout element: " JL_LAYOUT_NAME "\n"
    "Preferences: " JL_PREFERENCES_PATH "\n\n"
    "Features:\n"
    "- Windowed FFT (Hann or Blackman-Harris), bars or curve\n"
    "- Mid + side, horizontal or vertical layout\n"
    "- Solid, gradient and spectrum bar styles; four curve styles\n"
    "- Curve detail from full resolution to 1/3 octave\n"
    "- Logarithmic, compact-bass logarithmic or linear scale\n"
    "- Auto or fixed bar count, FFT size, dB top and range, slope\n"
    "- Attack/decay or RMS smoothing; peak line and shadow\n"
    "- dB scale, frequency axis and legend\n"
    "- Hover readout: frequency, note and level\n"
    "- Presets: Classic bars, RTA 1/3 octave, Fine detail, Mid + side\n"
    "- Full-screen view via double-click or context menu\n"
    "- Phosphor and other color themes, light/dark colors, glass background"
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
            return JLMatchesLayoutName(name);
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
