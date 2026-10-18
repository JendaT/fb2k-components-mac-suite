//
//  ThemeTokens.h
//  foo_wave_seekbar_mac
//
//  Colour tokens the waveform styles draw with. A theme supplies the accent
//  and background; deep, hot and the guide colours are derived in OKLCH so
//  they keep the accent's hue. Pure C++, tested standalone.
//

#pragma once

#include <cstdint>

namespace theme {

struct RGB {
    float r = 0, g = 0, b = 0;      // sRGB, 0..1
    static RGB fromARGB(uint32_t argb);
    bool operator==(const RGB& o) const { return r == o.r && g == o.g && b == o.b; }
};

struct Oklch {
    float L = 0, C = 0, h = 0;      // h in degrees
};

Oklch toOklch(const RGB& c);
// Out-of-gamut colours keep L and h and lose chroma until they fit sRGB.
RGB fromOklch(const Oklch& c);

// Linear sRGB mix, t = 0 -> a, 1 -> b
RGB mix(const RGB& a, const RGB& b, float t);

float luminance(const RGB& c);      // WCAG relative luminance
bool isDark(const RGB& background);

struct Tokens {
    RGB accent;     // main waveform colour
    RGB deep;       // dark end of gradients
    RGB hot;        // bright end of gradients
    RGB background;
    RGB grid;       // dB gridlines
    RGB centre;     // centre line
    RGB cursor;     // playback cursor and its time chip
    RGB cursorText;
};

// Deep: lightness x 0.55, chroma x 0.85. Hot: lightness 0.96, chroma at
// most 0.05. Grid and centre: the background moved 0.055 / 0.146 in
// lightness towards the other end, tinted with the accent hue.
Tokens deriveTokens(const RGB& accent, const RGB& background);

} // namespace theme
