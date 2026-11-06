#pragma once

//
// Names this component is known by: the About text, the layout element's
// match_name and the preferences info popover all read them from here.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_biography"
#define JL_COMPONENT_VERSION BIOGRAPHY_VERSION
#define JL_LAYOUT_NAME "biography"
// Other names match_name accepts. Never drop one: saved layouts refer to them.
#define JL_LAYOUT_ALIASES "Artist Biography", "Biography", "artist_biography", \
    "foo_jl_biography", "jl_biography"
#define JL_LAYOUT_PARAMETERS ""
#define JL_PREFERENCES_PATH "none"

#include "../../../../shared/component_info.h"
