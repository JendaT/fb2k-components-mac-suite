//
//  Main.mm
//  foo_jl_intake
//
//  Component registration for the intake system's SimPlaylist decorator
//  provider (intake doc 04, Part B).
//
//  This component has no layout element of its own in v1: it exists entirely
//  through SimPlaylist decorations (IntakeDecoratorProvider.mm), fed by the
//  loader that IntakeService.mm starts in on_init. Its settings live on the
//  Tools > Intake preferences page (IntakePreferencesController, B5).
//

#import "../fb2k_sdk.h"
#include "../../../../shared/version.h"

#import "../UI/IntakePreferencesController.h"
#include "IntakeConfig.h"

DECLARE_COMPONENT_VERSION(
    "Intake",
    INTAKE_VERSION,
    "Music intake pipeline: review and approve incoming releases from within "
    "SimPlaylist.\n\n"
    "Registers a row decorator provider that tints playlist rows by intake "
    "status and contributes intake actions to the context menu. All state is "
    "read from the intake CLI; this component mutates nothing directly.\n\n"
    "The CLI is set on the Tools > Intake preferences page. While its path is "
    "empty nothing runs and no row is decorated.\n\n"
    "MIT License - https://github.com/JendaT/fb2k-components-mac-suite"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_intake.component");

// Preferences page registration (the instantiate() signature of
// foo_jl_scrobble_mac Main.mm, not the one in knowledge_base 03).
namespace {

class intake_preferences_page : public preferences_page {
public:
    service_ptr instantiate() override {
        @autoreleasepool {
            return fb2k::wrapNSObject([[IntakePreferencesController alloc] init]);
        }
    }

    const char *get_name() override { return "Intake"; }

    GUID get_guid() override { return intake::config::kPreferencesPageGuid; }

    GUID get_parent_guid() override { return preferences_page::guid_tools; }
};

preferences_page_factory_t<intake_preferences_page> g_preferences_page_factory;

} // anonymous namespace
