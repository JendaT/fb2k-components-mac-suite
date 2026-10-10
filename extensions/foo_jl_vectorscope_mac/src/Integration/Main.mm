//
//  Main.mm
//  foo_jl_vectorscope_mac
//
//  Component registration and SDK integration.
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"

#import "../UI/VectorscopeController.h"

JL_COMPONENT_ABOUT(
    "Vectorscope",
    VECTORSCOPE_VERSION,
    "Stereo vectorscope (goniometer) for foobar2000 macOS\n\n"
    "Features:\n"
    "- Live goniometer of the playback stream with oscilloscope-style afterglow\n"
    "- Line or dot trace, adjustable persistence and brightness\n"
    "- Auto gain so quiet material still fills the scope\n"
    "- Phase correlation meter, broadband or low / mid / high\n"
    "- Color presets with light and dark mode colors\n"
    "- Glass background (translucent blur)"
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
            return strcmp(name, "Vectorscope") == 0 ||
                   strcmp(name, "vectorscope") == 0 ||
                   strcmp(name, "vector_scope") == 0 ||
                   strcmp(name, "goniometer") == 0 ||
                   strcmp(name, "foo_jl_vectorscope") == 0 ||
                   strcmp(name, "jl_vectorscope") == 0;
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
