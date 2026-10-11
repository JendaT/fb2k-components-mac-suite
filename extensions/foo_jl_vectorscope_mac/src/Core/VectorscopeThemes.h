//
//  VectorscopeThemes.h
//  foo_jl_vectorscope_mac
//
//  Curated color presets (same palettes as the Spectrum Analyzer). A theme
//  stamps the trace, background, grid, and band colors for both light and
//  dark appearance at once. Index 0 is "Custom" (applying it is a no-op);
//  real presets start at 1.
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
static const Theme kThemes[] = {
    // 0: Custom sentinel — values mirror Default but are never applied.
    { "Custom",
      0xFF1B8A3A, 0xFFF4F4F4, 0xFF9AA0A0,   0xFF33FF66, 0xFF0A0A0A, 0xFF4D4D4D,
      { 0xFFB86A00, 0xFF1B8A3A, 0xFF2E7DD1 },   { 0xFFFFB000, 0xFF33FF66, 0xFF4DA3F0 } },

    { "Default (Phosphor Green)",
      0xFF1B8A3A, 0xFFF4F4F4, 0xFF9AA0A0,   0xFF33FF66, 0xFF0A0A0A, 0xFF4D4D4D,
      { 0xFFB86A00, 0xFF1B8A3A, 0xFF2E7DD1 },   { 0xFFFFB000, 0xFF33FF66, 0xFF4DA3F0 } },

    { "Blue",
      0xFF2E7DD1, 0xFFF2F2F2, 0xFF808080,   0xFF4DA3F0, 0xFF161616, 0xFF909090,
      { 0xFFB86A00, 0xFF1F8F6B, 0xFF2E7DD1 },   { 0xFFF5A623, 0xFF4DD0A8, 0xFF4DA3F0 } },

    { "Amber",
      0xFFB86A00, 0xFFF7F3EA, 0xFFB4AA96,   0xFFFFB000, 0xFF0C0A06, 0xFF4D4433,
      { 0xFFB86A00, 0xFF6B8E12, 0xFF2A8FA8 },   { 0xFFFFB000, 0xFFB5D94A, 0xFF7CCBE0 } },

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
};

static const int kThemeCount = (int)(sizeof(kThemes) / sizeof(kThemes[0]));

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

} // namespace vectorscope_config
