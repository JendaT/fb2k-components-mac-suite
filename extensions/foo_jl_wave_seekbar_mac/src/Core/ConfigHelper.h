//
//  ConfigHelper.h
//  foo_wave_seekbar_mac
//
//  Helper for accessing fb2k::configStore API for persistent configuration
//

#pragma once

#include "../fb2k_sdk.h"

namespace waveform_config {

// Config key prefix for our component
static const char* const kConfigPrefix = "foo_wave_seekbar.";

// Helper functions for reading/writing config using fb2k::configStore
inline int64_t getConfigInt(const char* key, int64_t defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        int64_t val = store->getConfigInt(fullKey.c_str(), defaultVal);
        // Debug: console::info prints only in Debug builds
        FB2K_console_formatter() << "[WaveSeek] getConfigInt(" << fullKey.c_str() << ") = " << val;
        return val;
    } catch (std::exception& e) {
        FB2K_console_formatter() << "[WaveSeek] getConfigInt exception: " << e.what();
        return defaultVal;
    } catch (...) {
        FB2K_console_formatter() << "[WaveSeek] getConfigInt unknown exception";
        return defaultVal;
    }
}

inline void setConfigInt(const char* key, int64_t value) {
    try {
        auto store = fb2k::configStore::get();
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        FB2K_console_formatter() << "[WaveSeek] setConfigInt(" << fullKey.c_str() << ", " << value << ")";
        store->setConfigInt(fullKey.c_str(), value);
    } catch (std::exception& e) {
        FB2K_console_formatter() << "[WaveSeek] setConfigInt exception: " << e.what();
    } catch (...) {
        FB2K_console_formatter() << "[WaveSeek] setConfigInt unknown exception";
    }
}

inline bool getConfigBool(const char* key, bool defaultVal) {
    return getConfigInt(key, defaultVal ? 1 : 0) != 0;
}

inline void setConfigBool(const char* key, bool value) {
    setConfigInt(key, value ? 1 : 0);
}

// Config keys
static const char* const kKeyDisplayMode = "display_mode";
static const char* const kKeyShadePlayedPortion = "shade_played";
static const char* const kKeyPlayedDimming = "played_dimming";  // 0-100 percent
static const char* const kKeyCursorEffect = "cursor_effect";    // 0-6 (CursorEffect enum)
static const char* const kKeyWaveformStyle = "waveform_style";  // 0-2 (WaveformStyle enum)
static const char* const kKeyGradientBands = "gradient_bands";  // 2-32 bands for solid style
static const char* const kKeyBpmSync = "bpm_sync";              // Sync animations to BPM
static const char* const kKeyCacheSizeMB = "cache_size_mb";
static const char* const kKeyCacheRetentionDays = "cache_retention_days";
static const char* const kKeyWaveColorLight = "wave_color_light";
static const char* const kKeyBgColorLight = "bg_color_light";
static const char* const kKeyWaveColorDark = "wave_color_dark";
static const char* const kKeyBgColorDark = "bg_color_dark";
static const char* const kKeyLockWidth = "lock_width";
static const char* const kKeyLockedWidth = "locked_width";
static const char* const kKeyLockHeight = "lock_height";
static const char* const kKeyLockedHeight = "locked_height";

} // namespace waveform_config
