//
//  Main.mm
//  foo_jl_levelmeter_mac
//
//  Component registration and SDK integration.
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "ComponentInfo.h"
#include "../../../../shared/version.h"

#import "../UI/LevelMeterController.h"

JL_COMPONENT_ABOUT_BY(
    "Level Meter",
    LEVELMETER_VERSION,
    "Scannou",
    "Peak, RMS, loudness and VU meter for foobar2000 macOS\n\n"
    "Layout element: " JL_LAYOUT_NAME "\n"
    "Preferences: " JL_PREFERENCES_PATH "\n\n"
    "Features:\n"
    "- Digital bars: RMS with peak above it, peak hold, clip lights\n"
    "- True peak (4x oversampled) and sample peak modes\n"
    "- dBFS or K-20 / K-14 / K-12 scales, linear or extended spacing\n"
    "- Loudness (BS.1770 / EBU R128): momentary, short-term, integrated, range\n"
    "- True peak max, PLR and loudness target marker\n"
    "- Phase correlation and balance\n"
    "- Analog needle faces with VU or PPM ballistics and a peak LED\n"
    "- Vertical, horizontal or automatic layout; click to reset\n"
    "- Shared color themes, light/dark colors, glass background"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_levelmeter.component");

// UI Element service registration (embeddable view)
namespace {
    static const GUID g_guid_levelmeter_ui_element = {
        0xEBE8623F, 0x9D6E, 0x4E76,
        {0xBD, 0xEB, 0xE2, 0xFC, 0x01, 0x1F, 0xFC, 0x12}
    };

    class levelmeter_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                LevelMeterController* controller = [[LevelMeterController alloc] init];
                return fb2k::wrapNSObject(controller);
            }
        }

        bool match_name(const char* name) override {
            return JLMatchesLayoutName(name);
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("Level Meter");
        }

        GUID get_guid() override {
            return g_guid_levelmeter_ui_element;
        }
    };

    FB2K_SERVICE_FACTORY(levelmeter_ui_element);
}
