#pragma once

//
// Names this component is known by: the About text, the layout element's
// match_name and the preferences info popover all read them from here.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_vectorscope"
#define JL_COMPONENT_VERSION VECTORSCOPE_VERSION
#define JL_LAYOUT_NAME "vectorscope"
// Other names match_name accepts. Never drop one: saved layouts refer to them.
#define JL_LAYOUT_ALIASES "Vectorscope", "vector_scope", "goniometer", \
    "foo_jl_vectorscope", "jl_vectorscope"
#define JL_LAYOUT_PARAMETERS ""
#define JL_PREFERENCES_PATH "Display > Vectorscope"

#include "../../../../shared/component_info.h"
