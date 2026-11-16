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
//  Tools > Intake preferences page (IntakePreferencesController, B5). The
//  About text uses the suite's JL_COMPONENT_ABOUT with the names in
//  ComponentInfo.h.
//

#import "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"

#import "../UI/IntakePreferencesController.h"
#include "ComponentInfo.h"
#include "IntakeConfig.h"

JL_COMPONENT_ABOUT(
    "Intake",
    JL_COMPONENT_VERSION,
    "Shows music intake status on SimPlaylist rows and runs intake steps from the context menu.\n\n"
    "Layout element: " JL_LAYOUT_ELEMENT_NOTE "\n"
    "Preferences: " JL_PREFERENCES_PATH "\n\n"
    "Features:\n"
    "- Row tints and icons by intake status, with a marker on releases that need review\n"
    "- Group header badge with the target collection and confidence\n"
    "- Context actions: Propose, Assign, Approve, Reject, Execute, Resume, Swap to library paths "
    "and Delete local copy\n"
    "- All changes to music files and sidecars go through the intake command-line tool\n"
    "- Watches the income folders and reloads when a sidecar changes\n"
    "- Row colours and confirmations set in the preferences\n\n"
    "Requires SimPlaylist with the row decorator API and the intake command-line tool."
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
