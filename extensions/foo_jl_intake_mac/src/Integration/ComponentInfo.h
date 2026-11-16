#pragma once

//
// Names this component is known by: the About text (Main.mm) and the
// preferences info popover (IntakePreferencesController) read them from
// here.
//
// The component has no layout element: it decorates SimPlaylist rows. So it
// defines no JL_LAYOUT_* names and does not include shared/component_info.h,
// which requires a layout name and lists the layout aliases in its info
// rows. Like Effects DSP, the suite's other component without a layout
// element, the About text says "Layout element: none" instead.
//

#include "../../../../shared/version.h"

#define JL_COMPONENT_FILE "foo_jl_intake"
#define JL_COMPONENT_VERSION INTAKE_VERSION
#define JL_LAYOUT_ELEMENT_NOTE "none (decorates SimPlaylist rows)"
#define JL_PREFERENCES_PATH "Tools > Intake"
