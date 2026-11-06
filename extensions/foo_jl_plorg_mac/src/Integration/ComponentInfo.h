#pragma once

//
// Names this component is known by: the About text, the layout element's
// match_name and the preferences info popover all read them from here.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_plorg"
#define JL_COMPONENT_VERSION PLORG_VERSION
#define JL_LAYOUT_NAME "plorg"
// Other names match_name accepts. Never drop one: saved layouts refer to them.
#define JL_LAYOUT_ALIASES "Playlist Organizer", "playlist_organizer", \
    "playlist-organizer", "foo_plorg", "foo_jl_plorg", \
    "jl_plorg"
#define JL_LAYOUT_PARAMETERS ""
#define JL_PREFERENCES_PATH "Display > Playlist Organizer"

#include "../../../../shared/component_info.h"
