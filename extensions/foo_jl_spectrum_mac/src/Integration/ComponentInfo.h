#pragma once

//
// Names this component is known by: the About text, the layout element's
// match_name and the preferences info popover all read them from here.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_spectrum"
#define JL_COMPONENT_VERSION SPECTRUM_VERSION
#define JL_LAYOUT_NAME "spectrum"
// Other names match_name accepts. Never drop one: saved layouts refer to them.
#define JL_LAYOUT_ALIASES "Spectrum Analyzer", "spectrum_analyzer", "foo_jl_spectrum", \
    "jl_spectrum"
#define JL_LAYOUT_PARAMETERS ""
#define JL_PREFERENCES_PATH "Display > Spectrum Analyzer"

#include "../../../../shared/component_info.h"
