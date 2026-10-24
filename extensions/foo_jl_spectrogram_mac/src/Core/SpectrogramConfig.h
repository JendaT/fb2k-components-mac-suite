//
//  SpectrogramConfig.h
//  foo_jl_spectrogram_mac
//
//  Configuration GUIDs, enums, defaults, and fb2k::configStore accessors.
//  Config is persisted via fb2k::configStore (cfg_var does not persist on macOS v2).
//

#pragma once

#include "../fb2k_sdk.h"

namespace spectrogram_config {

// Preferences page GUID (shared by page registration and "open preferences" actions)
static const GUID guid_preferences_page = {
    0x8C4E1D27, 0x5A60, 0x4B9E,
    {0x93, 0x1F, 0x4A, 0xD2, 0x70, 0xB5, 0x3E, 0x61}
};

// Which signal is analysed (downmixed from the first two channels)
enum Channel {
    ChannelMid = 0,         // (L + R) / 2
    ChannelLeft = 1,
    ChannelRight = 2,
    ChannelSide = 3         // (L - R) / 2
};

// Which way the frequency axis runs, as in the Spectrum Analyzer: the same
// setting on both panels lines up their frequency axes.
enum Orientation {
    OrientationHorizontal = 0,  // Frequency along X, time flows vertically
    OrientationVertical = 1     // Frequency along Y, time flows sideways
};

// --- Defaults ---
// Enum-valued settings (analysis mode, frequency scale, window) store the
// SpectrogramEngine enum values directly.
constexpr int      kDefaultFftSize     = 4096;   // Base FFT window at 44.1/48 kHz (power of 2)
constexpr int      kDefaultAnalysisMode = 2;     // Reassigned: thin bass lines without time smear
constexpr int      kDefaultWindow      = 0;      // Hann
constexpr int      kDefaultChannel     = ChannelMid;
constexpr int      kDefaultFreqScale   = 0;      // Logarithmic
constexpr int      kDefaultMinHz       = 20;     // Lowest displayed frequency
constexpr int      kDefaultMaxHz       = 20000;  // Highest displayed frequency
constexpr int      kDefaultTopDb       = 0;      // Level mapped to the brightest color (dBFS)
constexpr int      kDefaultRangeDb     = 60;     // dB span below the top level
constexpr int      kDefaultSlopeTenths = 0;      // Tilt around 1 kHz, tenths of dB per octave
constexpr int      kDefaultColormap    = 0;      // Index into spectrogram_colormap::kMaps, or kCustomMap
constexpr int      kDefaultScrollSpeed = 120;    // Points per second
constexpr int      kDefaultOrientation = OrientationVertical;
constexpr bool     kDefaultReverseScroll = false; // New audio at the left (vertical) or bottom (horizontal)
constexpr bool     kDefaultShowFreqAxis = true;  // Frequency labels right of the plot
constexpr bool     kDefaultShowLegend  = true;   // Color/dB scale on the right edge
constexpr int      kDefaultGridOpacity = 15;     // Frequency gridline opacity 0-100 (0 hides)
constexpr int      kDefaultFreqFontSize = 11;    // Frequency label size, points
constexpr int      kDefaultDbFontSize  = 11;     // dB scale label size, points
constexpr int      kMinFontSize        = 8;
constexpr int      kMaxFontSize        = 16;

// Panel colors (ARGB): margins around the plot, and gridlines. Labels are
// derived from the background so they stay readable on any of them.
constexpr uint32_t kDefaultBgColorLight   = 0xFFF2F2F2;
constexpr uint32_t kDefaultBgColorDark    = 0xFF161616;
constexpr uint32_t kDefaultGridColorLight = 0xFF808080;
constexpr uint32_t kDefaultGridColorDark  = 0xFF909090;

// --- Config keys (stored under kConfigPrefix) ---
static const char* const kConfigPrefix     = "foo_jl_spectrogram.";
static const char* const kKeyFftSize        = "fft_size";
static const char* const kKeyAnalysisMode   = "analysis_mode";
static const char* const kKeyWindow         = "window";
static const char* const kKeyChannel        = "channel";
static const char* const kKeyFreqScale      = "freq_scale";
static const char* const kKeyMinHz          = "min_hz";
static const char* const kKeyMaxHz          = "max_hz";
static const char* const kKeyTopDb          = "top_db";
static const char* const kKeyRangeDb        = "range_db";
static const char* const kKeySlopeTenths    = "slope_tenths";
static const char* const kKeyColormap       = "colormap";
static const char* const kKeyScrollSpeed    = "scroll_speed";
static const char* const kKeyOrientation    = "orientation";
static const char* const kKeyReverseScroll  = "reverse_scroll";
static const char* const kKeyShowFreqAxis   = "show_freq_axis";
static const char* const kKeyShowLegend     = "show_legend";
static const char* const kKeyGridOpacity    = "grid_opacity";
static const char* const kKeyFreqFontSize   = "freq_font_size";
static const char* const kKeyDbFontSize     = "db_font_size";
static const char* const kKeyBgColorLight   = "bg_color_light";
static const char* const kKeyBgColorDark    = "bg_color_dark";
static const char* const kKeyGridColorLight = "grid_color_light";
static const char* const kKeyGridColorDark  = "grid_color_dark";
// Custom colormap: floor, low, mid, peak (see spectrogram_colormap::kCustomStops)
static const char* const kKeyCustomColors[] = {
    "custom_color_floor", "custom_color_low", "custom_color_mid", "custom_color_peak"
};

// Notification posted when preferences change so live views can reload.
// Guarded so this header stays includable from pure C++ translation units.
#ifdef __OBJC__
static NSString* const kSettingsChangedNotification = @"SpectrogramSettingsChanged";
#endif

// --- configStore accessors ---
inline int64_t getConfigInt(const char* key, int64_t defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        return store->getConfigInt(fullKey.c_str(), defaultVal);
    } catch (...) {
        return defaultVal;
    }
}

inline void setConfigInt(const char* key, int64_t value) {
    try {
        auto store = fb2k::configStore::get();
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        store->setConfigInt(fullKey.c_str(), value);
    } catch (...) {
    }
}

inline bool getConfigBool(const char* key, bool defaultVal) {
    return getConfigInt(key, defaultVal ? 1 : 0) != 0;
}

inline void setConfigBool(const char* key, bool value) {
    setConfigInt(key, value ? 1 : 0);
}

} // namespace spectrogram_config
