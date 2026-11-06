#pragma once

//
// Names this component is known by: the About text, the layout element's
// match_name and the preferences info popover all read them from here.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_simplaylist"
#define JL_COMPONENT_VERSION SIMPLAYLIST_VERSION
#define JL_LAYOUT_NAME "simplaylist"
// Other names match_name accepts. Never drop one: saved layouts refer to them.
#define JL_LAYOUT_ALIASES "SimPlaylist", "sim_playlist", "Simple Playlist", \
    "foo_simplaylist", "foo_jl_simplaylist", "jl_simplaylist"
#define JL_LAYOUT_PARAMETERS ""
#define JL_PREFERENCES_PATH "Display > SimPlaylist"

#include "../../../../shared/component_info.h"
