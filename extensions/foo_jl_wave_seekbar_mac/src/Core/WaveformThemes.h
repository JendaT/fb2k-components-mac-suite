//
//  WaveformThemes.h
//  foo_wave_seekbar_mac
//
//  Color presets matching Spectrum Analyzer's themes (same names, colors and
//  indices). A theme stamps the waveform and background colors for both light
//  and dark appearance at once. Index 0 is "Custom" (applying it is a no-op);
//  real presets start at 1. The selected theme isn't stored: it is whichever
//  preset matches the configured colors, so hand-picked colors read as Custom.
//

#pragma once

#include "WaveformConfig.h"   // default colors
#include "ConfigHelper.h"

namespace waveform_config {

struct Theme {
    const char* name;
    uint32_t waveLight, bgLight;
    uint32_t waveDark,  bgDark;
};

// ARGB (0xAARRGGBB). Light variants adapt each palette to a light background.
static const Theme kThemes[] = {
    // 0: Custom sentinel - never applied.
    { "Custom",          0xFF2E7DD1, 0xFFF2F2F2,   0xFF4DA3F0, 0xFF161616 },

    { "Default (Blue)",  0xFF2E7DD1, 0xFFF2F2F2,   0xFF4DA3F0, 0xFF161616 },
    { "Classic (Green)", 0xFF1B8A3A, 0xFFF4F4F4,   0xFF33FF66, 0xFF0A0A0A },
    { "Nord",            0xFF5E81AC, 0xFFECEFF4,   0xFF88C0D0, 0xFF2E3440 },
    { "Dracula",         0xFF8B5CF6, 0xFFF8F8F2,   0xFFBD93F9, 0xFF282A36 },
    { "Gruvbox",         0xFFD65D0E, 0xFFFBF1C7,   0xFFFE8019, 0xFF282828 },
    { "Solarized",       0xFF268BD2, 0xFFFDF6E3,   0xFF268BD2, 0xFF002B36 },
    { "Tokyo Night",     0xFF3D59A1, 0xFFD5D6DB,   0xFF7AA2F7, 0xFF1A1B26 },
    { "Catppuccin",      0xFF8839EF, 0xFFEFF1F5,   0xFFCBA6F7, 0xFF1E1E2E },
    { "Monokai",         0xFF4E9A06, 0xFFF8F8F2,   0xFFA6E22E, 0xFF272822 },
    { "Sunset",          0xFFE8551A, 0xFFFFF3EC,   0xFFFF6B35, 0xFF1A0F0A },

    // CRT phosphors. Listed first in the menu (kThemeMenuOrder).
    { "P31 green",       0xFF1B8A3A, 0xFFF1F5F2,   0xFF4CFF7C, 0xFF0C120E },
    { "P3 amber",        0xFFB86A00, 0xFFF7F3EA,   0xFFFFB000, 0xFF130F07 },
    { "P4 white",        0xFF3C434B, 0xFFF4F5F6,   0xFFE6EDF2, 0xFF0F1113 },
    { "P7 blue",         0xFF2D6CC0, 0xFFF0F4F9,   0xFF6FB7FF, 0xFF0A0E15 },
};

static const int kThemeCount = (int)(sizeof(kThemes) / sizeof(kThemes[0]));
static_assert(sizeof(kThemes) / sizeof(kThemes[0]) == 15, "update kThemeMenuOrder");

// Theme menu order: Custom, the phosphors, then the rest.
static const int kThemeMenuOrder[] = { 0, 11, 12, 13, 14, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

// Write a preset's colors into config. No-op for index 0 (Custom) or invalid.
inline void applyThemeToConfig(int index) {
    if (index <= 0 || index >= kThemeCount) return;
    const Theme& t = kThemes[index];
    setConfigInt(kKeyWaveColorLight, t.waveLight);
    setConfigInt(kKeyBgColorLight,   t.bgLight);
    setConfigInt(kKeyWaveColorDark,  t.waveDark);
    setConfigInt(kKeyBgColorDark,    t.bgDark);
}

// The preset whose four colors match config, or 0 (Custom) if none does.
inline int themeMatchingConfig() {
    const uint32_t waveLight = (uint32_t)getConfigInt(kKeyWaveColorLight, kDefaultWaveColorLight);
    const uint32_t bgLight   = (uint32_t)getConfigInt(kKeyBgColorLight,   kDefaultBgColorLight);
    const uint32_t waveDark  = (uint32_t)getConfigInt(kKeyWaveColorDark,  kDefaultWaveColorDark);
    const uint32_t bgDark    = (uint32_t)getConfigInt(kKeyBgColorDark,    kDefaultBgColorDark);
    for (int i = 1; i < kThemeCount; ++i) {
        const Theme& t = kThemes[i];
        if (t.waveLight == waveLight && t.bgLight == bgLight &&
            t.waveDark == waveDark && t.bgDark == bgDark) return i;
    }
    return 0;
}

} // namespace waveform_config
