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
};
#undef JL_SPECTROGRAM_MAP
constexpr int kMapCount = (int)(sizeof(kMaps) / sizeof(kMaps[0]));

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

} // namespace spectrogram_colormap
