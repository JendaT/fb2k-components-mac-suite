//
//  VectorscopeConfig.h
//  foo_jl_vectorscope_mac
//
//  Configuration GUIDs, enums, defaults, and fb2k::configStore accessors.
//  Config is persisted via fb2k::configStore (cfg_var does not persist on macOS v2).
//

#pragma once

#include "../fb2k_sdk.h"

namespace vectorscope_config {

// Preferences page GUID (shared by page registration and "open preferences" actions)
static const GUID guid_preferences_page = {
    0x24282F1C, 0xE338, 0x43FA,
    {0xBC, 0xAA, 0x31, 0x0D, 0xCB, 0xC5, 0xDD, 0xA4}
};

// How the trace is drawn
enum DrawMode {
    DrawModeLines = 0,      // Samples joined by lines; fast beam movement is dimmer
    DrawModeDots = 1        // One dot per sample
};

// Correlation meter layout
enum CorrelationMode {
    CorrelationSingle = 0,  // One broadband bar
    CorrelationBands = 1    // Low / mid / high bars
};

// --- Defaults ---
constexpr int      kDefaultDrawMode       = DrawModeLines;
constexpr int      kDefaultPersistenceMs  = 300;     // Afterglow time constant
constexpr int      kMinPersistenceMs      = 20;
constexpr int      kMaxPersistenceMs      = 2000;
constexpr int      kDefaultBrightness     = 60;      // Trace brightness 0-100
constexpr bool     kDefaultAutoGain       = true;    // Scale quiet material up to fill the scope
constexpr int      kDefaultGainDb         = 0;       // Fixed gain when auto gain is off
constexpr int      kMaxGainDb             = 36;
constexpr bool     kDefaultShowCorrelation = true;
constexpr int      kDefaultCorrelationMode = CorrelationSingle;
constexpr int      kDefaultIntegrationMs  = 500;     // Correlation time window
constexpr int      kMinIntegrationMs      = 100;
constexpr int      kMaxIntegrationMs      = 3000;
constexpr int      kDefaultLowHz          = 250;     // Low / mid crossover
constexpr int      kMinLowHz              = 40;
constexpr int      kMaxLowHz              = 1000;
constexpr int      kDefaultHighHz         = 2000;    // Mid / high crossover
constexpr int      kMinHighHz             = 1000;
constexpr int      kMaxHighHz             = 12000;
constexpr bool     kDefaultShowGrid       = true;    // Diamond, M/S axes, L/R diagonals
constexpr bool     kDefaultShowLabels     = true;    // L / R / M / S and correlation scale
constexpr int      kDefaultGridOpacity    = 40;      // Grid line opacity 0-100
constexpr int      kDefaultTheme          = 1;       // Color preset index (0 = Custom, 1 = Default)
constexpr bool     kDefaultGlassBackground = false;

// Default colors (ARGB)
constexpr uint32_t kDefaultTraceColorLight = 0xFF1B8A3A;  // Green
constexpr uint32_t kDefaultBgColorLight    = 0xFFF4F4F4;  // Light gray
constexpr uint32_t kDefaultGridColorLight  = 0xFF9AA0A0;  // Neutral gray
constexpr uint32_t kDefaultTraceColorDark  = 0xFF33FF66;  // Phosphor green
constexpr uint32_t kDefaultBgColorDark     = 0xFF0A0A0A;  // Near-black
constexpr uint32_t kDefaultGridColorDark   = 0xFF4D4D4D;  // Dark gray

// --- Config keys (stored under kConfigPrefix) ---
static const char* const kConfigPrefix        = "foo_jl_vectorscope.";
static const char* const kKeyDrawMode         = "draw_mode";
static const char* const kKeyPersistenceMs    = "persistence_ms";
static const char* const kKeyBrightness       = "brightness";
static const char* const kKeyAutoGain         = "auto_gain";
static const char* const kKeyGainDb           = "gain_db";
static const char* const kKeyShowCorrelation  = "show_correlation";
static const char* const kKeyCorrelationMode  = "correlation_mode";
static const char* const kKeyIntegrationMs    = "integration_ms";
static const char* const kKeyLowHz            = "xover_low_hz";
static const char* const kKeyHighHz           = "xover_high_hz";
static const char* const kKeyShowGrid         = "show_grid";
static const char* const kKeyShowLabels       = "show_labels";
static const char* const kKeyGridOpacity      = "grid_opacity";
static const char* const kKeyTheme            = "color_theme";
static const char* const kKeyGlassBackground  = "glass_background";
static const char* const kKeyTraceColorLight  = "trace_color_light";
static const char* const kKeyBgColorLight     = "bg_color_light";
static const char* const kKeyGridColorLight   = "grid_color_light";
static const char* const kKeyTraceColorDark   = "trace_color_dark";
static const char* const kKeyBgColorDark      = "bg_color_dark";
static const char* const kKeyGridColorDark    = "grid_color_dark";

// Notification posted when preferences change so live views can reload.
// Guarded so this header stays includable from pure C++ translation units.
#ifdef __OBJC__
static NSString* const kSettingsChangedNotification = @"VectorscopeSettingsChanged";
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

// Stored values are user-editable; keep them inside the range the controls offer.
inline int getConfigIntClamped(const char* key, int defaultVal, int lo, int hi) {
    const int64_t v = getConfigInt(key, defaultVal);
    return (int)(v < lo ? lo : (v > hi ? hi : v));
}

} // namespace vectorscope_config
