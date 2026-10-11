//
//  SpectrogramColormapsTests.cpp
//  foo_jl_spectrogram_mac
//
//  Unit tests for the color ramps and their lookup tables.
//  Standalone: no SDK, no Xcode.
//

#include "TestHarness.h"
#include "../src/Core/SpectrogramColormaps.h"

using namespace spectrogram_colormap;

int main() {
    for (int m = 0; m < kMapCount; ++m) {
        const Map& map = kMaps[m];
        g_context = map.name;

        CHECK(map.count >= 2, "at least two stops");
        CHECK_FLOAT_EQ(map.stops[0].pos, 0.0, "first stop at 0");
        CHECK_FLOAT_EQ(map.stops[map.count - 1].pos, 1.0, "last stop at 1");
        for (int i = 1; i < map.count; ++i) {
            CHECK(map.stops[i].pos > map.stops[i - 1].pos, "stops ascend");
        }

        uint32_t lut[kLutSize];
        buildLut(m, lut);
        CHECK_EQ(lut[0], 0xFF000000u | map.stops[0].rgb, "floor is the first stop");
        CHECK_EQ(lut[kLutSize - 1], 0xFF000000u | map.stops[map.count - 1].rgb, "top is the last stop");
        for (int i = 0; i < kLutSize; ++i) {
            CHECK_EQ(lut[i] >> 24, 0xFF, "opaque");
        }
    }

    g_context = "interpolation";
    // Grayscale is a single black-to-white segment: the midpoint is mid gray.
    const Map& gray = kMaps[kMapCount - 1];
    CHECK_EQ(colorAt(gray, 0.5f), 0xFF808080u, "midpoint of black to white");
    CHECK_EQ(colorAt(gray, -1.0f), 0xFF000000u, "below range clamps to the floor");
    CHECK_EQ(colorAt(gray, 2.0f), 0xFFFFFFFFu, "above range clamps to the top");

    g_context = "bad index";
    uint32_t first[kLutSize], fallback[kLutSize];
    buildLut(0, first);
    buildLut(-3, fallback);
    CHECK_EQ(fallback[100], first[100], "negative index falls back to the first map");
    buildLut(kMapCount, fallback);
    CHECK_EQ(fallback[200], first[200], "index past the end falls back to the first map");

    TEST_MAIN_END();
}
