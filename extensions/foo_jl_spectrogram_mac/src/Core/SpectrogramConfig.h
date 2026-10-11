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

// --- Defaults ---
// Enum-valued settings (frequency scale, window) store the SpectrogramEngine
// enum values directly; 0 is the default for both.
constexpr int      kDefaultFftSize     = 4096;   // Base FFT window at 44.1/48 kHz (power of 2)
constexpr bool     kDefaultMultiRes    = true;   // Longer window for bass, shorter for treble
constexpr int      kDefaultWindow      = 0;      // Hann
constexpr int      kDefaultChannel     = ChannelMid;
constexpr int      kDefaultFreqScale   = 0;      // Logarithmic
constexpr int      kDefaultMinHz       = 20;     // Lowest displayed frequency
constexpr int      kDefaultMaxHz       = 20000;  // Highest displayed frequency
constexpr int      kDefaultTopDb       = 0;      // Level mapped to the brightest color (dBFS)
constexpr int      kDefaultRangeDb     = 90;     // dB span below the top level
constexpr int      kDefaultSlopeTenths = 0;      // Tilt around 1 kHz, tenths of dB per octave
constexpr int      kDefaultColormap    = 0;      // Index into spectrogram_colormap::kMaps
constexpr int      kDefaultScrollSpeed = 120;    // Points per second
constexpr bool     kDefaultShowFreqAxis = true;  // Frequency labels on the left edge
constexpr bool     kDefaultShowLegend  = true;   // Color/dB scale on the right edge
constexpr int      kDefaultGridOpacity = 15;     // Frequency gridline opacity 0-100 (0 hides)

// --- Config keys (stored under kConfigPrefix) ---
static const char* const kConfigPrefix     = "foo_jl_spectrogram.";
static const char* const kKeyFftSize        = "fft_size";
static const char* const kKeyMultiRes       = "multi_res";
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
static const char* const kKeyShowFreqAxis   = "show_freq_axis";
static const char* const kKeyShowLegend     = "show_legend";
static const char* const kKeyGridOpacity    = "grid_opacity";

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
