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
    const Map& gray = kMaps[kFirstThemeMap - 1];
    CHECK(std::string(gray.name) == "Grayscale", "grayscale is the last map before the themes");
    CHECK_EQ(colorAt(gray, 0.5f), 0xFF808080u, "midpoint of black to white");
    CHECK_EQ(colorAt(gray, -1.0f), 0xFF000000u, "below range clamps to the floor");
    CHECK_EQ(colorAt(gray, 2.0f), 0xFFFFFFFFu, "above range clamps to the top");

    g_context = "themes";
    CHECK(std::string(kMaps[kFirstThemeMap].name) == "Default (Blue)", "theme maps start at kFirstThemeMap");
    for (int m = kFirstThemeMap; m < kMapCount; ++m) {
        // Each theme ramp rises from its background: the floor is darker than the top.
        const uint32_t lo = kMaps[m].stops[0].rgb, hi = kMaps[m].stops[kMaps[m].count - 1].rgb;
        auto luma = [](uint32_t c) { return 0.2126 * ((c >> 16) & 0xFF) + 0.7152 * ((c >> 8) & 0xFF) + 0.0722 * (c & 0xFF); };
        CHECK(luma(lo) < 60.0 && luma(hi) > 180.0, kMaps[m].name);  // Nord and Dracula sit near 50
    }

    g_context = "custom";
    // Seeding the custom ramp from a preset reproduces the preset at its stops.
    for (int m = 0; m < kMapCount; ++m) {
        uint32_t colors[kCustomColorCount], lut[kLutSize];
        for (int i = 0; i < kCustomColorCount; ++i) colors[i] = 0xFF000000u | customColorFromMap(m, i);
        buildCustomLut(colors, lut);
        CHECK_EQ(lut[0], colors[0], "floor is the floor color");
        CHECK_EQ(lut[kLutSize - 1], colors[kCustomColorCount - 1], "top is the peak color");
        CHECK_EQ(colors[0], 0xFF000000u | kMaps[m].stops[0].rgb, "floor sampled from the preset");
    }
    uint32_t twoTone[kCustomColorCount] = {0xFF000000u, 0xFF000000u, 0xFFFFFFFFu, 0xFFFFFFFFu}, lut2[kLutSize];
    buildCustomLut(twoTone, lut2);
    CHECK_EQ(lut2[50], 0xFF000000u, "flat between two equal stops");
    CHECK_EQ(lut2[220], 0xFFFFFFFFu, "flat above the mid stop");
    CHECK((lut2[134] & 0xFF) > 0x40 && (lut2[134] & 0xFF) < 0xC0, "ramps between low and mid");

    g_context = "accent";
    auto mapIndex = [](const char* name) {
        for (int m = 0; m < kMapCount; ++m) if (std::string(kMaps[m].name) == name) return m;
        return -1;
    };
    uint32_t lutA[kLutSize];
    buildLut(mapIndex("Grayscale"), lutA);
    CHECK_EQ(accentColor(lutA), 0xFFFFFFFFu, "colorless map: its top");
    buildLut(mapIndex("Inferno"), lutA);
    {
        const uint32_t a = accentColor(lutA);
        CHECK(((a >> 16) & 0xFF) > 0xE0 && (a & 0xFF) < 0x60, "Inferno: a saturated orange-yellow, not its pale top");
    }
    buildLut(mapIndex("P3 amber"), lutA);
    {
        // The accent stop (0.85) falls between two table entries: within 2 per channel.
        const uint32_t a = accentColor(lutA), want = 0xFFFFB000u;
        bool close = true;
        for (int shift = 0; shift <= 16; shift += 8) {
            close = close && std::abs((int)((a >> shift) & 0xFF) - (int)((want >> shift) & 0xFF)) <= 2;
        }
        CHECK(close, "theme ramp: the theme accent");
    }

    g_context = "color space";
    CHECK(isDisplayP3Map(kCustomMap), "custom ramp is P3 (user colors)");
    CHECK(!isDisplayP3Map(0) && !isDisplayP3Map(kFirstThemeMap - 1), "general-purpose maps are sRGB");
    CHECK(isDisplayP3Map(kFirstThemeMap) && isDisplayP3Map(kMapCount - 1), "theme ramps are P3 (theme colors)");

    g_context = "bad index";
    uint32_t first[kLutSize], fallback[kLutSize];
    buildLut(0, first);
    buildLut(-3, fallback);
    CHECK_EQ(fallback[100], first[100], "negative index falls back to the first map");
    buildLut(kMapCount, fallback);
    CHECK_EQ(fallback[200], first[200], "index past the end falls back to the first map");

    TEST_MAIN_END();
}
