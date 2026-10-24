//
//  SpectrogramColormaps.h
//  foo_jl_spectrogram_mac
//
//  Color ramps that map a normalized level (0 = floor, 1 = top) to a color.
//  Pure C++ (no SDK, no Cocoa) so it can be unit-tested and reused.
//

#pragma once

#include <cstdint>

namespace spectrogram_colormap {

struct Stop {
    float    pos;   // 0..1, ascending
    uint32_t rgb;   // 0xRRGGBB
};

struct Map {
    const char* name;
    const Stop* stops;
    int         count;
};

constexpr int kLutSize = 256;

// Perceptually uniform ramps (matplotlib), sampled at ten even stops.
static const Stop kInferno[] = {
    {0.000f, 0x000004}, {0.111f, 0x1B0C41}, {0.222f, 0x4A0C6B}, {0.333f, 0x781C6D},
    {0.444f, 0xA52C60}, {0.556f, 0xCF4446}, {0.667f, 0xED6925}, {0.778f, 0xFB9B06},
    {0.889f, 0xF7D13D}, {1.000f, 0xFCFFA4}
};
static const Stop kMagma[] = {
    {0.000f, 0x000004}, {0.111f, 0x180F3D}, {0.222f, 0x440F76}, {0.333f, 0x721F81},
    {0.444f, 0x9E2F7F}, {0.556f, 0xCD4071}, {0.667f, 0xF1605D}, {0.778f, 0xFD9668},
    {0.889f, 0xFECA8D}, {1.000f, 0xFCFDBF}
};
static const Stop kPlasma[] = {
    {0.000f, 0x0D0887}, {0.111f, 0x46039F}, {0.222f, 0x7201A8}, {0.333f, 0x9C179E},
    {0.444f, 0xBD3786}, {0.556f, 0xD8576B}, {0.667f, 0xED7953}, {0.778f, 0xFB9F3A},
    {0.889f, 0xFDCA26}, {1.000f, 0xF0F921}
};
static const Stop kViridis[] = {
    {0.000f, 0x440154}, {0.111f, 0x482878}, {0.222f, 0x3E4989}, {0.333f, 0x31688E},
    {0.444f, 0x26828E}, {0.556f, 0x1F9E89}, {0.667f, 0x35B779}, {0.778f, 0x6ECE58},
    {0.889f, 0xB5DE2B}, {1.000f, 0xFDE725}
};
static const Stop kTurbo[] = {
    {0.000f, 0x30123B}, {0.111f, 0x4662D7}, {0.222f, 0x36AAF9}, {0.333f, 0x1AE4B6},
    {0.444f, 0x72FE5E}, {0.556f, 0xC7EF34}, {0.667f, 0xFABA39}, {0.778f, 0xF66B19},
    {0.889f, 0xCA2A04}, {1.000f, 0x7A0403}
};
// Hardware-analyzer ramp: black, blue, purple, red, yellow, white.
static const Stop kClassic[] = {
    {0.00f, 0x000000}, {0.20f, 0x000040}, {0.40f, 0x1C1CE0}, {0.55f, 0x8412C4},
    {0.68f, 0xD0106A}, {0.78f, 0xE42410}, {0.89f, 0xF2C814}, {1.00f, 0xFFFFFF}
};
static const Stop kIce[] = {
    {0.00f, 0x000000}, {0.30f, 0x061A4A}, {0.55f, 0x1560C0}, {0.80f, 0x4FD0F0},
    {1.00f, 0xFFFFFF}
};
static const Stop kHeat[] = {
    {0.00f, 0x000000}, {0.35f, 0x7A0000}, {0.60f, 0xF03000}, {0.85f, 0xFFD000},
    {1.00f, 0xFFFFFF}
};
static const Stop kGray[] = {
    {0.00f, 0x000000}, {1.00f, 0xFFFFFF}
};

// Ramps from the Spectrum Analyzer color themes (dark variants): the theme's
// background, rising through its accent color to a near-white top.
static const Stop kThemeBlue[] = {
    {0.00f, 0x161616}, {0.30f, 0x264057}, {0.65f, 0x4287C4}, {0.85f, 0x4DA3F0}, {1.00f, 0xD2E8FB}
};
static const Stop kThemeGreen[] = {
    {0.00f, 0x0A0A0A}, {0.30f, 0x165426}, {0.65f, 0x2BCE54}, {0.85f, 0x33FF66}, {1.00f, 0xCCFFD9}
};
static const Stop kThemeNord[] = {
    {0.00f, 0x2E3440}, {0.30f, 0x495E6B}, {0.65f, 0x76A4B3}, {0.85f, 0x88C0D0}, {1.00f, 0xE1EFF3}
};
static const Stop kThemeDracula[] = {
    {0.00f, 0x282A36}, {0.30f, 0x554A70}, {0.65f, 0x9F7ED2}, {0.85f, 0xBD93F9}, {1.00f, 0xEEE4FE}
};
static const Stop kThemeGruvbox[] = {
    {0.00f, 0x282828}, {0.30f, 0x684224}, {0.65f, 0xD36E1C}, {0.85f, 0xFE8019}, {1.00f, 0xFFDFC6}
};
static const Stop kThemeSolarized[] = {
    {0.00f, 0x002B36}, {0.30f, 0x0B4865}, {0.65f, 0x1E78B3}, {0.85f, 0x268BD2}, {1.00f, 0xC9E2F4}
};
static const Stop kThemeTokyoNight[] = {
    {0.00f, 0x1A1B26}, {0.30f, 0x374465}, {0.65f, 0x6787CD}, {0.85f, 0x7AA2F7}, {1.00f, 0xDEE8FD}
};
static const Stop kThemeCatppuccin[] = {
    {0.00f, 0x1E1E2E}, {0.30f, 0x52476A}, {0.65f, 0xA88BCF}, {0.85f, 0xCBA6F7}, {1.00f, 0xF2E9FD}
};
static const Stop kThemeMonokai[] = {
    {0.00f, 0x272822}, {0.30f, 0x4D6026}, {0.65f, 0x8DBD2C}, {0.85f, 0xA6E22E}, {1.00f, 0xE9F8CB}
};
static const Stop kThemeSunset[] = {
    {0.00f, 0x1A0F0A}, {0.30f, 0x5F2B17}, {0.65f, 0xD1592C}, {0.85f, 0xFF6B35}, {1.00f, 0xFFDACC}
};
static const Stop kThemeP31[] = {
    {0.00f, 0x0C120E}, {0.30f, 0x1F592F}, {0.65f, 0x3FD066}, {0.85f, 0x4CFF7C}, {1.00f, 0xD2FFDE}
};
static const Stop kThemeP3[] = {
    {0.00f, 0x130F07}, {0.30f, 0x5A3F05}, {0.65f, 0xD09001}, {0.85f, 0xFFB000}, {1.00f, 0xFFEBBF}
};
static const Stop kThemeP4[] = {
    {0.00f, 0x0F1113}, {0.30f, 0x505356}, {0.65f, 0xBBC1C5}, {0.85f, 0xE6EDF2}, {1.00f, 0xF9FAFC}
};
static const Stop kThemeP7[] = {
    {0.00f, 0x0A0E15}, {0.30f, 0x28415B}, {0.65f, 0x5B95D0}, {0.85f, 0x6FB7FF}, {1.00f, 0xDBEDFF}
};

#define JL_SPECTROGRAM_MAP(name, stops) { name, stops, (int)(sizeof(stops) / sizeof(stops[0])) }
static const Map kMaps[] = {
    JL_SPECTROGRAM_MAP("Inferno", kInferno),
    JL_SPECTROGRAM_MAP("Magma", kMagma),
    JL_SPECTROGRAM_MAP("Classic", kClassic),
    JL_SPECTROGRAM_MAP("Ice", kIce),
    JL_SPECTROGRAM_MAP("Heat", kHeat),
    JL_SPECTROGRAM_MAP("Plasma", kPlasma),
    JL_SPECTROGRAM_MAP("Viridis", kViridis),
    JL_SPECTROGRAM_MAP("Turbo", kTurbo),
    JL_SPECTROGRAM_MAP("Grayscale", kGray),
    // Theme ramps start here (kFirstThemeMap). New maps go at the end so a
    // saved index keeps its meaning.
    JL_SPECTROGRAM_MAP("Default (Blue)", kThemeBlue),
    JL_SPECTROGRAM_MAP("Classic (Green)", kThemeGreen),
    JL_SPECTROGRAM_MAP("Nord", kThemeNord),
    JL_SPECTROGRAM_MAP("Dracula", kThemeDracula),
    JL_SPECTROGRAM_MAP("Gruvbox", kThemeGruvbox),
    JL_SPECTROGRAM_MAP("Solarized", kThemeSolarized),
    JL_SPECTROGRAM_MAP("Tokyo Night", kThemeTokyoNight),
    JL_SPECTROGRAM_MAP("Catppuccin", kThemeCatppuccin),
    JL_SPECTROGRAM_MAP("Monokai", kThemeMonokai),
    JL_SPECTROGRAM_MAP("Sunset", kThemeSunset),
    JL_SPECTROGRAM_MAP("P31 green", kThemeP31),
    JL_SPECTROGRAM_MAP("P3 amber", kThemeP3),
    JL_SPECTROGRAM_MAP("P4 white", kThemeP4),
    JL_SPECTROGRAM_MAP("P7 blue", kThemeP7),
};
#undef JL_SPECTROGRAM_MAP
constexpr int kMapCount = (int)(sizeof(kMaps) / sizeof(kMaps[0]));
constexpr int kFirstThemeMap = 9;  // index of "Default (Blue)"

// Panel colors of the Spectrum Analyzer theme behind each theme ramp (ARGB),
// in kMaps order from kFirstThemeMap. Choosing a theme ramp stamps these.
struct ThemePanel {
    uint32_t bgLight, gridLight, bgDark, gridDark;
};
static const ThemePanel kThemePanels[] = {
    {0xFFF2F2F2, 0xFF808080, 0xFF161616, 0xFF909090},   // Default (Blue)
    {0xFFF4F4F4, 0xFF9AA0A0, 0xFF0A0A0A, 0xFF4D4D4D},   // Classic (Green)
    {0xFFECEFF4, 0xFFB0B6C0, 0xFF2E3440, 0xFF4C566A},   // Nord
    {0xFFF8F8F2, 0xFFCFCFD6, 0xFF282A36, 0xFF44475A},   // Dracula
    {0xFFFBF1C7, 0xFFBDB4A0, 0xFF282828, 0xFF504945},   // Gruvbox
    {0xFFFDF6E3, 0xFF93A1A1, 0xFF002B36, 0xFF586E75},   // Solarized
    {0xFFD5D6DB, 0xFFA8AECB, 0xFF1A1B26, 0xFF414868},   // Tokyo Night
    {0xFFEFF1F5, 0xFFBCC0CC, 0xFF1E1E2E, 0xFF45475A},   // Catppuccin
    {0xFFF8F8F2, 0xFFC8C8B8, 0xFF272822, 0xFF49483E},   // Monokai
    {0xFFFFF3EC, 0xFFD8B8A0, 0xFF1A0F0A, 0xFF4D3326},   // Sunset
    {0xFFF1F5F2, 0xFF5F7A66, 0xFF0C120E, 0xFFB8E6C4},   // P31 green
    {0xFFF7F3EA, 0xFF7D6E55, 0xFF130F07, 0xFFE8D4AE},   // P3 amber
    {0xFFF4F5F6, 0xFF6E767E, 0xFF0F1113, 0xFFD5DCE2},   // P4 white
    {0xFFF0F4F9, 0xFF64748A, 0xFF0A0E15, 0xFFC4D6EC},   // P7 blue
};
static_assert(sizeof(kThemePanels) / sizeof(kThemePanels[0]) == kMapCount - kFirstThemeMap,
              "one panel entry per theme ramp");

// "Custom": a ramp through four user colors at these positions.
constexpr int   kCustomMap = -1;
constexpr int   kCustomColorCount = 4;   // floor, low, mid, peak
constexpr float kCustomStops[kCustomColorCount] = {0.0f, 0.35f, 0.7f, 1.0f};

// Which color space a map's numbers are in. The theme ramps and the custom
// ramp are built from theme / user colors, which the suite stores as Display
// P3 (shared/ThemeColor.h). The general-purpose maps are defined in sRGB;
// reading them as P3 would distort them.
inline bool isDisplayP3Map(int index) {
    return index == kCustomMap || index >= kFirstThemeMap;
}

// Color at position t (0..1) as 0xFFRRGGBB, interpolated between stops.
inline uint32_t colorAt(const Map& map, float t) {
    if (t <= map.stops[0].pos) return 0xFF000000u | map.stops[0].rgb;
    for (int i = 1; i < map.count; ++i) {
        const Stop& a = map.stops[i - 1];
        const Stop& b = map.stops[i];
        if (t > b.pos) continue;
        const float u = (t - a.pos) / (b.pos - a.pos);
        uint32_t out = 0xFF000000u;
        for (int shift = 16; shift >= 0; shift -= 8) {
            const float ca = (float)((a.rgb >> shift) & 0xFF);
            const float cb = (float)((b.rgb >> shift) & 0xFF);
            out |= (uint32_t)(ca + (cb - ca) * u + 0.5f) << shift;
        }
        return out;
    }
    return 0xFF000000u | map.stops[map.count - 1].rgb;
}

// Fill `lut` (kLutSize entries, 0xFFRRGGBB) for the map at `index`.
// An out-of-range index (corrupted config) falls back to the first map.
inline void buildLut(int index, uint32_t* lut) {
    if (index < 0 || index >= kMapCount) index = 0;
    for (int i = 0; i < kLutSize; ++i) {
        lut[i] = colorAt(kMaps[index], (float)i / (float)(kLutSize - 1));
    }
}

// Fill `lut` for the custom ramp through `colors` (kCustomColorCount, ARGB).
inline void buildCustomLut(const uint32_t* colors, uint32_t* lut) {
    Stop stops[kCustomColorCount];
    for (int i = 0; i < kCustomColorCount; ++i) stops[i] = {kCustomStops[i], colors[i] & 0xFFFFFFu};
    const Map map = {"Custom", stops, kCustomColorCount};
    for (int i = 0; i < kLutSize; ++i) {
        lut[i] = colorAt(map, (float)i / (float)(kLutSize - 1));
    }
}

// The colormap's signature color for markers drawn over the picture (the
// frequency probe): the most vivid of its upper half, scored saturation x
// value, so a ramp that ends in white still yields its color (Inferno: orange,
// theme ramps: the theme accent). A colorless map yields its top.
inline uint32_t accentColor(const uint32_t* lut) {
    float best = -1.0f;
    uint32_t pick = lut[kLutSize - 1];
    for (int i = kLutSize / 2; i < kLutSize; ++i) {
        const float r = ((lut[i] >> 16) & 0xFF) / 255.0f;
        const float g = ((lut[i] >> 8) & 0xFF) / 255.0f;
        const float b = (lut[i] & 0xFF) / 255.0f;
        const float hi = r > g ? (r > b ? r : b) : (g > b ? g : b);
        const float lo = r < g ? (r < b ? r : b) : (g < b ? g : b);
        const float score = hi > 0.0f ? (hi - lo) : 0.0f;   // saturation x value
        if (score > best + 1e-4f) { best = score; pick = lut[i]; }
    }
    return best < 0.08f ? lut[kLutSize - 1] : pick;
}

// The custom colors that reproduce map `index` as closely as four stops can:
// the map sampled at kCustomStops. Used to seed the color wells.
inline uint32_t customColorFromMap(int index, int i) {
    if (index < 0 || index >= kMapCount) index = 0;
    return colorAt(kMaps[index], kCustomStops[i]);
}

} // namespace spectrogram_colormap
