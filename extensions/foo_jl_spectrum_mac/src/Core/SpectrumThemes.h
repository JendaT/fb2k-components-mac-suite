//
//  SpectrumThemes.h
//  foo_jl_spectrum_mac
//
//  Curated color presets (MiniMeters-style). A theme stamps the bar,
//  background, and grid colors for both light and dark appearance at once.
//  Index 0 is "Custom" (applying it is a no-op); real presets start at 1.
//

#pragma once

#include "SpectrumConfig.h"

namespace spectrum_config {

struct Theme {
    const char* name;
    uint32_t barLight,  bgLight,  gridLight;
    uint32_t barDark,   bgDark,   gridDark;
};

// ARGB (0xAARRGGBB). Light variants adapt each palette to a light background.
static const Theme kThemes[] = {
    // 0: Custom sentinel — values mirror Default but are never applied.
    { "Custom",
      0xFF2E7DD1, 0xFFF2F2F2, 0xFF808080,   0xFF4DA3F0, 0xFF161616, 0xFF909090 },

    { "Default (Blue)",
      0xFF2E7DD1, 0xFFF2F2F2, 0xFF808080,   0xFF4DA3F0, 0xFF161616, 0xFF909090 },

    { "Classic (Green)",
      0xFF1B8A3A, 0xFFF4F4F4, 0xFF9AA0A0,   0xFF33FF66, 0xFF0A0A0A, 0xFF4D4D4D },

    { "Nord",
      0xFF5E81AC, 0xFFECEFF4, 0xFFB0B6C0,   0xFF88C0D0, 0xFF2E3440, 0xFF4C566A },

    { "Dracula",
      0xFF8B5CF6, 0xFFF8F8F2, 0xFFCFCFD6,   0xFFBD93F9, 0xFF282A36, 0xFF44475A },

    { "Gruvbox",
      0xFFD65D0E, 0xFFFBF1C7, 0xFFBDB4A0,   0xFFFE8019, 0xFF282828, 0xFF504945 },

    { "Solarized",
      0xFF268BD2, 0xFFFDF6E3, 0xFF93A1A1,   0xFF268BD2, 0xFF002B36, 0xFF586E75 },

    { "Tokyo Night",
      0xFF3D59A1, 0xFFD5D6DB, 0xFFA8AECB,   0xFF7AA2F7, 0xFF1A1B26, 0xFF414868 },

    { "Catppuccin",
      0xFF8839EF, 0xFFEFF1F5, 0xFFBCC0CC,   0xFFCBA6F7, 0xFF1E1E2E, 0xFF45475A },

    { "Monokai",
      0xFF4E9A06, 0xFFF8F8F2, 0xFFC8C8B8,   0xFFA6E22E, 0xFF272822, 0xFF49483E },

    { "Sunset",
      0xFFE8551A, 0xFFFFF3EC, 0xFFD8B8A0,   0xFFFF6B35, 0xFF1A0F0A, 0xFF4D3326 },
};

static const int kThemeCount = (int)(sizeof(kThemes) / sizeof(kThemes[0]));

// Write a preset's colors into config. No-op for index 0 (Custom) or invalid.
inline void applyThemeToConfig(int index) {
    if (index <= 0 || index >= kThemeCount) return;
    const Theme& t = kThemes[index];
    setConfigInt(kKeyBarColorLight,  t.barLight);
    setConfigInt(kKeyBgColorLight,   t.bgLight);
    setConfigInt(kKeyGridColorLight, t.gridLight);
    setConfigInt(kKeyBarColorDark,   t.barDark);
    setConfigInt(kKeyBgColorDark,    t.bgDark);
    setConfigInt(kKeyGridColorDark,  t.gridDark);
}

} // namespace spectrum_config
