// Effects DSP component registration
//
// Each effect registers its own dsp_factory_t<> in its .cpp file.
// This file provides the component version declaration.

#include "Effects/Echo.h"
#include "Effects/Tremolo.h"
#include "Effects/IIRFilter.h"
#include "Effects/Reverb.h"
#include "Effects/Phaser.h"
#include "Effects/WahWah.h"
#include "Effects/Chorus.h"
#include "Effects/Vibrato.h"
#include "Effects/PitchShift.h"
#include "Effects/TempoShift.h"
#include "Effects/RateShift.h"
#include "../../../../shared/version.h"
#include "../../../../shared/common_about.h"

JL_COMPONENT_ABOUT(
    "Effects DSP",
    EFFECTS_DSP_VERSION,
    "Collection of 11 audio effects for the foobar2000 DSP chain.\n\n"
    "Layout element: none (DSP only)\n"
    "Preferences: Playback > DSP Manager\n\n"
    "Features:\n"
    "- Echo with up to 5 s delay, feedback and wet/dry mix\n"
    "- Chorus, Vibrato and Tremolo\n"
    "- Phaser (2-12 stages) and WahWah\n"
    "- Reverb based on Freeverb\n"
    "- IIR Filter with 12 biquad filter types\n"
    "- Pitch Shift up to +/-12 semitones\n"
    "- Tempo Shift and Rate Shift, -50% to +100%\n"
    "- Settings window with sliders for each effect\n\n"
    "Based on foo_dsp_effect by mudlord (Unlicense).\n"
    "Uses SoundTouch by Olli Parviainen (LGPL 2.1)\n"
    "and Freeverb (public domain)."
);

VALIDATE_COMPONENT_FILENAME("foo_jl_effects_dsp.component");
