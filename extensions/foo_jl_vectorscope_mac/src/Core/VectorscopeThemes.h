//
//  VectorscopeThemes.h
//  foo_jl_vectorscope_mac
//
//  Color presets matching the Spectrum Analyzer's themes (same names, colors
//  and indices). A theme stamps the trace, background, grid, and band colors
//  for both light and dark appearance at once. Index 0 is "Custom" (applying
//  it is a no-op); real presets start at 1. The selected theme isn't stored:
//  it is whichever preset matches the configured colors, so hand-picked
//  colors read as Custom.
//
//  Band colors (low, mid, high) come from each palette's own accents, warm
//  to cool, and keep clear of red: the correlation meter uses red for
//  out-of-phase readings.
//

#pragma once

#include "VectorscopeConfig.h"

namespace vectorscope_config {

struct Theme {
    const char* name;
    uint32_t traceLight, bgLight, gridLight;
    uint32_t traceDark,  bgDark,  gridDark;
    uint32_t bandLight[kBandCount];
    uint32_t bandDark[kBandCount];
};

// ARGB (0xAARRGGBB). Light variants adapt each palette to a light background.
// Same names, indices, and trace/background/grid colors as the Spectrum
// Analyzer and Waveform Seekbar themes.
static const Theme kThemes[] = {
    // 0: Custom sentinel - never applied.
    { "Custom",
      0xFF1B8A3A, 0xFFF4F4F4, 0xFF9AA0A0,   0xFF33FF66, 0xFF0A0A0A, 0xFF4D4D4D,
      { 0xFFB86A00, 0xFF1B8A3A, 0xFF2E7DD1 },   { 0xFFFFB000, 0xFF33FF66, 0xFF4DA3F0 } },

    { "Default (Blue)",
      0xFF2E7DD1, 0xFFF2F2F2, 0xFF808080,   0xFF4DA3F0, 0xFF161616, 0xFF909090,
      { 0xFFB86A00, 0xFF1F8F6B, 0xFF2E7DD1 },   { 0xFFF5A623, 0xFF4DD0A8, 0xFF4DA3F0 } },

    { "Classic (Green)",
      0xFF1B8A3A, 0xFFF4F4F4, 0xFF9AA0A0,   0xFF33FF66, 0xFF0A0A0A, 0xFF4D4D4D,
      { 0xFFB86A00, 0xFF1B8A3A, 0xFF2E7DD1 },   { 0xFFFFB000, 0xFF33FF66, 0xFF4DA3F0 } },

    { "Nord",
      0xFF5E81AC, 0xFFECEFF4, 0xFFB0B6C0,   0xFF88C0D0, 0xFF2E3440, 0xFF4C566A,
      { 0xFFB37A1E, 0xFF5E8D4E, 0xFF5E81AC },   { 0xFFEBCB8B, 0xFFA3BE8C, 0xFF88C0D0 } },

    { "Dracula",
      0xFF8B5CF6, 0xFFF8F8F2, 0xFFCFCFD6,   0xFFBD93F9, 0xFF282A36, 0xFF44475A,
      { 0xFFD97706, 0xFF8B5CF6, 0xFF0E9BB5 },   { 0xFFFFB86C, 0xFFBD93F9, 0xFF8BE9FD } },

    { "Gruvbox",
      0xFFD65D0E, 0xFFFBF1C7, 0xFFBDB4A0,   0xFFFE8019, 0xFF282828, 0xFF504945,
      { 0xFFC46A08, 0xFF79740E, 0xFF076678 },   { 0xFFFE8019, 0xFFB8BB26, 0xFF83A598 } },

    { "Solarized",
      0xFF268BD2, 0xFFFDF6E3, 0xFF93A1A1,   0xFF268BD2, 0xFF002B36, 0xFF586E75,
      { 0xFFB58900, 0xFF2AA198, 0xFF6C71C4 },   { 0xFFB58900, 0xFF2AA198, 0xFF6C71C4 } },

    { "Tokyo Night",
      0xFF3D59A1, 0xFFD5D6DB, 0xFFA8AECB,   0xFF7AA2F7, 0xFF1A1B26, 0xFF414868,
      { 0xFFB15C00, 0xFF587539, 0xFF3D59A1 },   { 0xFFE0AF68, 0xFF9ECE6A, 0xFF7AA2F7 } },

    { "Catppuccin",
      0xFF8839EF, 0xFFEFF1F5, 0xFFBCC0CC,   0xFFCBA6F7, 0xFF1E1E2E, 0xFF45475A,
      { 0xFFC7791A, 0xFF8839EF, 0xFF1E66F5 },   { 0xFFF9E2AF, 0xFFCBA6F7, 0xFF89DCEB } },

    { "Monokai",
      0xFF4E9A06, 0xFFF8F8F2, 0xFFC8C8B8,   0xFFA6E22E, 0xFF272822, 0xFF49483E,
      { 0xFFCF7A00, 0xFF4E9A06, 0xFF1F9FB5 },   { 0xFFFD971F, 0xFFA6E22E, 0xFF66D9EF } },

    { "Sunset",
      0xFFE8551A, 0xFFFFF3EC, 0xFFD8B8A0,   0xFFFF6B35, 0xFF1A0F0A, 0xFF4D3326,
      { 0xFFC77700, 0xFFC2399A, 0xFF7C4DDB },   { 0xFFFFB347, 0xFFF472B6, 0xFFA78BFA } },

    // CRT phosphors. Listed first in the menu (kThemeMenuOrder). Their bands
    // borrow the other phosphors: P3 amber low, P31 green mid, P7 blue high,
    // with the theme's own colour taking its place.
    { "P31 green",
      0xFF1B8A3A, 0xFFF1F5F2, 0xFF5F7A66,   0xFF4CFF7C, 0xFF0C120E, 0xFFB8E6C4,
      { 0xFFB86A00, 0xFF1B8A3A, 0xFF2D6CC0 },   { 0xFFFFB000, 0xFF4CFF7C, 0xFF6FB7FF } },

    { "P3 amber",
      0xFFB86A00, 0xFFF7F3EA, 0xFF7D6E55,   0xFFFFB000, 0xFF130F07, 0xFFE8D4AE,
      { 0xFFB86A00, 0xFF6B8E12, 0xFF2A8FA8 },   { 0xFFFFB000, 0xFFB5D94A, 0xFF7CCBE0 } },

    { "P4 white",
      0xFF3C434B, 0xFFF4F5F6, 0xFF6E767E,   0xFFE6EDF2, 0xFF0F1113, 0xFFD5DCE2,
      { 0xFFB86A00, 0xFF3C434B, 0xFF2D6CC0 },   { 0xFFFFB000, 0xFFE6EDF2, 0xFF6FB7FF } },

    { "P7 blue",
      0xFF2D6CC0, 0xFFF0F4F9, 0xFF64748A,   0xFF6FB7FF, 0xFF0A0E15, 0xFFC4D6EC,
      { 0xFFB86A00, 0xFF1B8A3A, 0xFF2D6CC0 },   { 0xFFFFB000, 0xFF4CFF7C, 0xFF6FB7FF } },
};

static const int kThemeCount = (int)(sizeof(kThemes) / sizeof(kThemes[0]));
static_assert(sizeof(kThemes) / sizeof(kThemes[0]) == 15, "update kThemeMenuOrder");

// Theme menu order: Custom, the phosphors, then the rest.
static const int kThemeMenuOrder[] = { 0, 11, 12, 13, 14, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

// Write a preset's colors into config. No-op for index 0 (Custom) or invalid.
inline void applyThemeToConfig(int index) {
    if (index <= 0 || index >= kThemeCount) return;
    const Theme& t = kThemes[index];
    setConfigInt(kKeyTraceColorLight, t.traceLight);
    setConfigInt(kKeyBgColorLight,    t.bgLight);
    setConfigInt(kKeyGridColorLight,  t.gridLight);
    setConfigInt(kKeyTraceColorDark,  t.traceDark);
    setConfigInt(kKeyBgColorDark,     t.bgDark);
    setConfigInt(kKeyGridColorDark,   t.gridDark);
    for (int b = 0; b < kBandCount; ++b) {
        setConfigInt(kKeyBandColorLight[b], t.bandLight[b]);
        setConfigInt(kKeyBandColorDark[b],  t.bandDark[b]);
    }
}

// The preset whose colors all match config, or 0 (Custom) if none does.
inline int themeMatchingConfig() {
    const auto is = [](const char* key, uint32_t def, uint32_t want) {
        return (uint32_t)getConfigInt(key, def) == want;
    };
    for (int i = 1; i < kThemeCount; ++i) {
        const Theme& t = kThemes[i];
        bool match = is(kKeyTraceColorLight, kDefaultTraceColorLight, t.traceLight) &&
                     is(kKeyBgColorLight,    kDefaultBgColorLight,    t.bgLight) &&
                     is(kKeyGridColorLight,  kDefaultGridColorLight,  t.gridLight) &&
                     is(kKeyTraceColorDark,  kDefaultTraceColorDark,  t.traceDark) &&
                     is(kKeyBgColorDark,     kDefaultBgColorDark,     t.bgDark) &&
                     is(kKeyGridColorDark,   kDefaultGridColorDark,   t.gridDark);
        for (int b = 0; match && b < kBandCount; ++b) {
            match = is(kKeyBandColorLight[b], kDefaultBandColorLight[b], t.bandLight[b]) &&
                    is(kKeyBandColorDark[b],  kDefaultBandColorDark[b],  t.bandDark[b]);
        }
        if (match) return i;
    }
    return 0;
}

} // namespace vectorscope_config
