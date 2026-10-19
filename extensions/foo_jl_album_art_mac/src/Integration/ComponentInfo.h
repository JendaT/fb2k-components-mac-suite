#pragma once

//
// Names this component is known by: the About text, the layout element's
// match_name and the preferences info popover all read them from here.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_album_art"
#define JL_COMPONENT_VERSION ALBUMART_VERSION
#define JL_LAYOUT_NAME "albumart_ext"
// Other names match_name accepts. Never drop one: saved layouts refer to them.
#define JL_LAYOUT_ALIASES "Album Art (Extended)", "foo_jl_album_art", "jl_album_art", \
    "jl_albumart", "jl_albumart_ext"
#define JL_LAYOUT_PARAMETERS "type=front|back|disc|icon|artist, square"
#define JL_PREFERENCES_PATH "none (right-click the panel for options)"

#include "../../../../shared/component_info.h"
