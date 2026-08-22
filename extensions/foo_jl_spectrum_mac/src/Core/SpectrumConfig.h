//
//  SpectrumConfig.h
//  foo_jl_spectrum_mac
//
//  Configuration GUIDs, enums, defaults, and fb2k::configStore accessors.
//  Config is persisted via fb2k::configStore (cfg_var does not persist on macOS v2).
//

#pragma once

#include "../fb2k_sdk.h"

namespace spectrum_config {

// Preferences page GUID (shared by page registration and "open preferences" actions)
static const GUID guid_preferences_page = {
    0x2F9A7C41, 0x8B3D, 0x4E62,
    {0xA1, 0x05, 0x9D, 0x77, 0x3C, 0x18, 0x6E, 0x2A}
};

// Bar fill styles
enum BarStyle {
    BarStyleSolid = 0,      // Single color
    BarStyleGradient = 1,   // Vertical gradient (bottom -> top)
    BarStyleSpectrum = 2    // Hue mapped across frequency (low -> high)
};

// Frequency axis mapping
enum FreqScale {
    FreqScaleLog = 0,       // Logarithmic (musically natural)
    FreqScaleLinear = 1     // Linear
};

// --- Defaults ---
constexpr int      kDefaultBarCount   = 48;      // Number of frequency bars
constexpr int      kDefaultFftSize    = 4096;    // FFT window (power of 2)
constexpr int      kDefaultBarStyle   = BarStyleGradient;
constexpr int      kDefaultFreqScale  = FreqScaleLog;
constexpr int      kDefaultMinHz      = 20;      // Lowest displayed frequency
constexpr int      kDefaultMaxHz      = 20000;   // Highest displayed frequency
constexpr int      kDefaultGapPercent = 20;      // Gap between bars, % of slot width
constexpr int      kDefaultSmoothing  = 60;      // Temporal smoothing 0-100 (higher = smoother)
constexpr int      kDefaultShadowFallSpeed = 40; // Shadow band fall speed 0-100 (higher = faster)
constexpr int      kDefaultPeakFallSpeed   = 30; // Peak line fall speed 0-100 (higher = faster)
constexpr int      kDefaultPeakHoldMs      = 400;// Peak line hold time before it starts falling (ms)
constexpr bool     kDefaultPeakHold   = true;    // Show falling peak caps
constexpr bool     kDefaultShowDbGuides = true;  // Show dB scale on the right edge
constexpr bool     kDefaultShowFreqAxis = true;  // Show frequency labels/gridlines
constexpr bool     kDefaultShadowFill = true;    // Slow-decaying dim fill behind bars
constexpr int      kDefaultGridOpacity = 40;     // Grid line opacity 0-100
constexpr bool     kDefaultGlassBackground = false;

// dB window that maps to the 0..1 bar height. Shared by the analyzer (scaling)
// and the view (dB guide placement) so the guides line up with the bars.
constexpr float    kDisplayFloorDb = -80.0f;     // maps to bar height 0
constexpr float    kDisplayCeilDb  = 0.0f;       // maps to bar height 1

// Default colors (ARGB)
constexpr uint32_t kDefaultBarColorLight = 0xFF2E7DD1;  // Blue
constexpr uint32_t kDefaultBgColorLight  = 0xFFF2F2F2;  // Light gray
constexpr uint32_t kDefaultBarColorDark  = 0xFF4DA3F0;  // Lighter blue
constexpr uint32_t kDefaultBgColorDark   = 0xFF161616;  // Near-black
constexpr uint32_t kDefaultGridColorLight = 0xFF808080; // Neutral gray
constexpr uint32_t kDefaultGridColorDark  = 0xFF909090; // Neutral gray

// --- Config keys (stored under kConfigPrefix) ---
static const char* const kConfigPrefix     = "foo_jl_spectrum.";
static const char* const kKeyBarCount       = "bar_count";
static const char* const kKeyFftSize        = "fft_size";
static const char* const kKeyBarStyle       = "bar_style";
static const char* const kKeyFreqScale      = "freq_scale";
static const char* const kKeyMinHz          = "min_hz";
static const char* const kKeyMaxHz          = "max_hz";
static const char* const kKeyGapPercent     = "gap_percent";
static const char* const kKeySmoothing      = "smoothing";
static const char* const kKeyShadowFallSpeed = "shadow_fall_speed";
static const char* const kKeyPeakFallSpeed   = "peak_fall_speed";
static const char* const kKeyPeakHoldMs      = "peak_hold_ms";
static const char* const kKeyPeakHold       = "peak_hold";
static const char* const kKeyShowDbGuides   = "show_db_guides";
static const char* const kKeyShowFreqAxis   = "show_freq_axis";
static const char* const kKeyShadowFill     = "shadow_fill";
static const char* const kKeyGridOpacity    = "grid_opacity";
static const char* const kKeyGridColorLight = "grid_color_light";
static const char* const kKeyGridColorDark  = "grid_color_dark";
static const char* const kKeyGlassBackground = "glass_background";
static const char* const kKeyBarColorLight  = "bar_color_light";
static const char* const kKeyBgColorLight   = "bg_color_light";
static const char* const kKeyBarColorDark   = "bar_color_dark";
static const char* const kKeyBgColorDark    = "bg_color_dark";

// Notification posted when preferences change so live views can reload.
// Guarded so this header stays includable from pure C++ translation units.
#ifdef __OBJC__
static NSString* const kSettingsChangedNotification = @"SpectrumAnalyzerSettingsChanged";
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

} // namespace spectrum_config
