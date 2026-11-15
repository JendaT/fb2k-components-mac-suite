//
//  DebugFakeBeatgrid.mm
//  foo_wave_seekbar_mac
//
//  Debug-only stand-in for BPM Analyzer's beat grids (shared/
//  jl_beatgrid_fake.h), for trying the phrase markers without it. NOT
//  SHIPPED: compiles only in Debug builds, and registers only when
//  foobar2000 is launched with WAVESEEK_BEATGRID_FAKE=1. Never together
//  with the real BPM Analyzer installed (both would answer the same GUID).
//
//      WAVESEEK_BEATGRID_FAKE=1 open -a foobar2000
//

#if DEBUG

#include "../fb2k_sdk.h"
#include "../../../../shared/jl_beatgrid_fake.h"

#include <cstdlib>

namespace {

struct FakeBeatgridRegistrar {
    FakeBeatgridRegistrar() {
        const char *on = std::getenv("WAVESEEK_BEATGRID_FAKE");
        if (on && on[0] == '1' && on[1] == '\0') jl_beatgrid_fake_register();
    }
} g_fakeBeatgridRegistrar;

}  // namespace

#endif  // DEBUG
