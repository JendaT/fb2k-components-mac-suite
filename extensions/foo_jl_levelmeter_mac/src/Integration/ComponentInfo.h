#pragma once

//
// Names this component is known by: the About text, the layout element's
// match_name and the preferences info popover all read them from here.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_levelmeter"
#define JL_COMPONENT_VERSION LEVELMETER_VERSION
#define JL_LAYOUT_NAME "level_meter"
// Other names match_name accepts. Never drop one: saved layouts refer to them.
#define JL_LAYOUT_ALIASES "Level Meter", "levelmeter", "vu_meter", "VU Meter", "vumeter", \
    "peak_meter", "loudness_meter", "foo_jl_levelmeter", "jl_levelmeter"
#define JL_LAYOUT_PARAMETERS ""
#define JL_PREFERENCES_PATH "Display > Level Meter"

#include "../../../../shared/component_info.h"
