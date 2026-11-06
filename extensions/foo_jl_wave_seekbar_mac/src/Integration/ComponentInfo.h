#pragma once

//
// Names this component is known by: the About text, the layout element's
// match_name and the preferences info popover all read them from here.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_wave_seekbar"
#define JL_COMPONENT_VERSION WAVEFORM_VERSION
#define JL_LAYOUT_NAME "waveform-seekbar"
// Other names match_name accepts. Never drop one: saved layouts refer to them.
#define JL_LAYOUT_ALIASES "Waveform Seekbar", "waveform_seekbar", \
    "waveform-seekbar-mac", "wave_seekbar", "foo_wave_seekbar", \
    "foo_jl_wave_seekbar", "jl_wave_seekbar"
#define JL_LAYOUT_PARAMETERS ""
#define JL_PREFERENCES_PATH "Display > Waveform Seekbar"

#include "../../../../shared/component_info.h"
