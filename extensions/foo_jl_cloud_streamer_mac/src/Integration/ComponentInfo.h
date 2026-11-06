#pragma once

//
// Names this component is known by: the About text, the layout element's
// match_name and the preferences info popover all read them from here.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_cloud_streamer"
#define JL_COMPONENT_VERSION CLOUD_STREAMER_VERSION
#define JL_LAYOUT_NAME "cloud_browser"
// Other names match_name accepts. Never drop one: saved layouts refer to them.
#define JL_LAYOUT_ALIASES "Cloud Browser", "CloudBrowser", "Cloud browser", \
    "cloud browser", "foo_jl_cloud_browser", "jl_cloud_browser"
#define JL_LAYOUT_PARAMETERS ""
#define JL_PREFERENCES_PATH "Tools > Cloud Streamer"

#include "../../../../shared/component_info.h"
