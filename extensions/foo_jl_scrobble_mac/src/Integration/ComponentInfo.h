#pragma once

//
// Names this component is known by: the About text, the layout element's
// match_name and the preferences info popover all read them from here.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_scrobble"
#define JL_COMPONENT_VERSION SCROBBLE_VERSION
#define JL_LAYOUT_NAME "lastfm_scrobbler"
// Other names match_name accepts. Never drop one: saved layouts refer to them.
#define JL_LAYOUT_ALIASES "Last.fm Scrobbler", "lastfm-scrobbler", "foo_jl_scrobble", \
    "jl_scrobble", "scrobbler"
#define JL_LAYOUT_PARAMETERS ""
#define JL_PREFERENCES_PATH "Tools > Last.fm Scrobbler"

#include "../../../../shared/component_info.h"
