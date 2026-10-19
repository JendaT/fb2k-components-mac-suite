//
//  Main.mm
//  foo_jl_vectorscope_mac
//
//  Component registration and SDK integration.
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "ComponentInfo.h"
#include "../../../../shared/version.h"

#import "../UI/VectorscopeController.h"

JL_COMPONENT_ABOUT_BY(
    "Vectorscope",
    VECTORSCOPE_VERSION,
    "Scannou",
    "Stereo vectorscope (goniometer) for foobar2000 macOS\n\n"
    "Layout element: " JL_LAYOUT_NAME "\n"
    "Preferences: " JL_PREFERENCES_PATH "\n\n"
    "Features:\n"
    "- Goniometer (mid/side) or Lissajous (left/right) display\n"
    "- Oscilloscope-style afterglow, adjustable persistence\n"
    "- Line or dot trace, adjustable brightness and dot size\n"
    "- Optional low / mid / high band-colored trace\n"
    "- Auto gain so quiet material fills the scope, or fixed gain\n"
    "- Phase correlation meter, broadband or low / mid / high\n"
    "- Meter on any side, with a recent-range hold band\n"
    "- Grid with level guides and L / R / M / S labels\n"
    "- Color presets, light/dark colors, glass background"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_vectorscope.component");

// UI Element service registration (embeddable view)
namespace {
    static const GUID g_guid_vectorscope_ui_element = {
        0xD468544C, 0xF42E, 0x4413,
        {0x82, 0xBA, 0xA3, 0x88, 0x19, 0xBD, 0xD8, 0xAB}
    };

    class vectorscope_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                VectorscopeController* controller = [[VectorscopeController alloc] init];
                return fb2k::wrapNSObject(controller);
            }
        }

        bool match_name(const char* name) override {
            return JLMatchesLayoutName(name);
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("Vectorscope");
        }

        GUID get_guid() override {
            return g_guid_vectorscope_ui_element;
        }
    };

    FB2K_SERVICE_FACTORY(vectorscope_ui_element);
}
