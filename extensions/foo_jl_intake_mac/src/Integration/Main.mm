//
//  Main.mm
//  foo_jl_intake
//
//  Component registration for the intake system's SimPlaylist decorator
//  provider (intake doc 04, Part B).
//
//  This component has no layout element of its own in v1: it exists entirely
//  through SimPlaylist decorations (IntakeDecoratorProvider.mm), fed by the
//  loader that IntakeService.mm starts in on_init.
//

#import "../fb2k_sdk.h"
#include "../../../../shared/version.h"

DECLARE_COMPONENT_VERSION(
    "Intake",
    INTAKE_VERSION,
    "Music intake pipeline: review and approve incoming releases from within "
    "SimPlaylist.\n\n"
    "Registers a row decorator provider that tints playlist rows by intake "
    "status and contributes intake actions to the context menu. All state is "
    "read from the intake CLI; this component mutates nothing directly.\n\n"
    "The CLI is set by the foo_jl_intake.cli_path setting (no preferences page "
    "yet). While it is empty nothing runs and no row is decorated.\n\n"
    "MIT License - https://github.com/JendaT/fb2k-components-mac-suite"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_intake.component");
