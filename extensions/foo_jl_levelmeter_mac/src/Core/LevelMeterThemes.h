//
//  LevelMeterThemes.h
//  foo_jl_levelmeter_mac
//
//  Colour presets with the same names and order as the other visualisers'
//  themes. Each sets the six meter colours for light and dark appearance.
//  Index 0 is "Custom" (never applied). Pure C++, no SDK.
//
//  Level colour = the theme's trace colour; warning = its warm accent;
//  loudness = its cool accent; over = its red.
//

#pragma once

#include "DisplaySettings.h"

namespace meter {

struct MeterTheme {
    const char *name;
    // background, text, safe, warn, over, loudness
    uint32_t light[6];
    uint32_t dark[6];
};

static const MeterTheme kMeterThemes[] = {
    { "Custom",
      { 0xFFF4F4F4, 0xFF30353B, 0xFF1B8A3A, 0xFFB86A00, 0xFFD70015, 0xFF2E7DD1 },
      { 0xFF0A0A0A, 0xFFC9CED4, 0xFF33FF66, 0xFFFFB000, 0xFFFF453A, 0xFF4DA3F0 } },

    { "Default (Blue)",
      { 0xFFF2F2F2, 0xFF30353B, 0xFF2E7DD1, 0xFFB86A00, 0xFFD70015, 0xFF1F8F6B },
      { 0xFF161616, 0xFFC9CED4, 0xFF4DA3F0, 0xFFF5A623, 0xFFFF453A, 0xFF4DD0A8 } },

    { "Classic (Green)",
      { 0xFFF4F4F4, 0xFF30353B, 0xFF1B8A3A, 0xFFB86A00, 0xFFD70015, 0xFF2E7DD1 },
      { 0xFF0A0A0A, 0xFFC9CED4, 0xFF33FF66, 0xFFFFB000, 0xFFFF453A, 0xFF4DA3F0 } },

    { "Nord",
      { 0xFFECEFF4, 0xFF2E3440, 0xFF5E8D4E, 0xFFB37A1E, 0xFFBF616A, 0xFF5E81AC },
      { 0xFF2E3440, 0xFFD8DEE9, 0xFFA3BE8C, 0xFFEBCB8B, 0xFFBF616A, 0xFF88C0D0 } },

    { "Dracula",
      { 0xFFF8F8F2, 0xFF44475A, 0xFF8B5CF6, 0xFFD97706, 0xFFD9302F, 0xFF0E9BB5 },
      { 0xFF282A36, 0xFFE6E6EA, 0xFFBD93F9, 0xFFFFB86C, 0xFFFF5555, 0xFF8BE9FD } },

    { "Gruvbox",
      { 0xFFFBF1C7, 0xFF3C3836, 0xFF79740E, 0xFFC46A08, 0xFF9D0006, 0xFF076678 },
      { 0xFF282828, 0xFFEBDBB2, 0xFFB8BB26, 0xFFFE8019, 0xFFFB4934, 0xFF83A598 } },

    { "Solarized",
      { 0xFFFDF6E3, 0xFF586E75, 0xFF2AA198, 0xFFB58900, 0xFFDC322F, 0xFF268BD2 },
      { 0xFF002B36, 0xFF93A1A1, 0xFF2AA198, 0xFFB58900, 0xFFDC322F, 0xFF268BD2 } },

    { "Tokyo Night",
      { 0xFFD5D6DB, 0xFF343B58, 0xFF587539, 0xFFB15C00, 0xFF8C4351, 0xFF3D59A1 },
      { 0xFF1A1B26, 0xFFC0CAF5, 0xFF9ECE6A, 0xFFE0AF68, 0xFFF7768E, 0xFF7AA2F7 } },

    { "Catppuccin",
      { 0xFFEFF1F5, 0xFF4C4F69, 0xFF40A02B, 0xFFC7791A, 0xFFD20F39, 0xFF1E66F5 },
      { 0xFF1E1E2E, 0xFFCDD6F4, 0xFFA6E3A1, 0xFFF9E2AF, 0xFFF38BA8, 0xFF89DCEB } },

    { "Monokai",
      { 0xFFF8F8F2, 0xFF49483E, 0xFF4E9A06, 0xFFCF7A00, 0xFFC4105A, 0xFF1F9FB5 },
      { 0xFF272822, 0xFFE6E6E0, 0xFFA6E22E, 0xFFFD971F, 0xFFF92672, 0xFF66D9EF } },

    { "Sunset",
      { 0xFFFFF3EC, 0xFF5A3A2A, 0xFFE8551A, 0xFFC77700, 0xFFC2185B, 0xFF7C4DDB },
      { 0xFF1A0F0A, 0xFFF0D8C8, 0xFFFF6B35, 0xFFFFB347, 0xFFF43F5E, 0xFFA78BFA } },

    { "P31 green",
      { 0xFFF1F5F2, 0xFF2F4A36, 0xFF1B8A3A, 0xFFB86A00, 0xFFD70015, 0xFF2D6CC0 },
      { 0xFF0C120E, 0xFFB8E6C4, 0xFF4CFF7C, 0xFFFFB000, 0xFFFF453A, 0xFF6FB7FF } },

    { "P3 amber",
      { 0xFFF7F3EA, 0xFF4D4030, 0xFFB86A00, 0xFF8A5A00, 0xFFD70015, 0xFF2A8FA8 },
      { 0xFF130F07, 0xFFE8D4AE, 0xFFFFB000, 0xFFFFD27A, 0xFFFF453A, 0xFF7CCBE0 } },

    { "P4 white",
      { 0xFFF4F5F6, 0xFF3C434B, 0xFF3C434B, 0xFFB86A00, 0xFFD70015, 0xFF2D6CC0 },
      { 0xFF0F1113, 0xFFD5DCE2, 0xFFE6EDF2, 0xFFFFB000, 0xFFFF453A, 0xFF6FB7FF } },

    { "P7 blue",
      { 0xFFF0F4F9, 0xFF2F3D52, 0xFF2D6CC0, 0xFFB86A00, 0xFFD70015, 0xFF1B8A3A },
      { 0xFF0A0E15, 0xFFC4D6EC, 0xFF6FB7FF, 0xFFFFB000, 0xFFFF453A, 0xFF4CFF7C } },
};

static const int kMeterThemeCount = (int)(sizeof(kMeterThemes) / sizeof(kMeterThemes[0]));
static_assert(sizeof(kMeterThemes) / sizeof(kMeterThemes[0]) == 15, "update kMeterThemeMenuOrder");

// Menu order: Custom, the phosphors, then the rest (as the other visualisers).
static const int kMeterThemeMenuOrder[] = { 0, 11, 12, 13, 14, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

constexpr int kDefaultMeterTheme = 2;   // Classic (Green)

} // namespace meter
