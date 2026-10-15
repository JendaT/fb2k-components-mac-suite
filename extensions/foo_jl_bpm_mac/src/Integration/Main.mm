//
//  Main.mm
//  foo_jl_bpm_mac
//
//  Component registration. The commands live in BpmMenu.mm.
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"

JL_COMPONENT_ABOUT(
    "BPM Analyzer",
    BPM_VERSION,
    "Tempo (BPM) analysis and tagging for foobar2000 macOS\n\n"
    "Features:\n"
    "- Analyze BPM: finds the tempo of the selected tracks and shows the results for review before writing the BPM tag\n"
    "- Uses TIDAL's tempo for tracks it matches by ISRC when the Tidal component is installed\n"
    "- Analyzes everything else locally (decoded audio, several tracks at a time)\n"
    "- Double BPM and Halve BPM fix half/double tempo tags"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_bpm.component");
