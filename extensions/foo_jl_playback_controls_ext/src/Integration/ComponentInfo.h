#pragma once

//
// Names this component is known by: the About text, the layout element's
// match_name and the preferences info popover all read them from here.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_playback_controls"
#define JL_COMPONENT_VERSION PLAYBACK_CONTROLS_VERSION
#define JL_LAYOUT_NAME "playback_controls"
// Other names match_name accepts. Never drop one: saved layouts refer to them.
#define JL_LAYOUT_ALIASES "Playback Controls", "transport", "transport_controls", \
    "PlaybackControls"
#define JL_LAYOUT_PARAMETERS ""
#define JL_PREFERENCES_PATH "none (right-click the panel for options)"

#include "../../../../shared/component_info.h"
