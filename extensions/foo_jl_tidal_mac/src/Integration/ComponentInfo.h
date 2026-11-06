#pragma once

//
// Names this component is known by: the About text, the layout element's
// match_name and the preferences info popover all read them from here.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_tidal"
#define JL_COMPONENT_VERSION TIDAL_VERSION
#define JL_LAYOUT_NAME "tidal-browser"
// Other names match_name accepts. Never drop one: saved layouts refer to them.
#define JL_LAYOUT_ALIASES "Tidal Browser", "tidal_browser", "TidalBrowser", \
    "foo_jl_tidal_browser"
#define JL_LAYOUT_PARAMETERS ""
#define JL_PREFERENCES_PATH "Tools > Tidal"

#include "../../../../shared/component_info.h"
