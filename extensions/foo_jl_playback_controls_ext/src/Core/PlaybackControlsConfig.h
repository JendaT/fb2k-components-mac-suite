//
//  PlaybackControlsConfig.h
//  foo_jl_playback_controls_ext
//
//  Configuration storage using fb2k::configStore
//

#pragma once

#include "../fb2k_sdk.h"
#include <string>

namespace playback_controls_config {

// Configuration key prefix
static const char* const kPrefix = "foo_playback_controls.";

// Configuration keys
static const char* const kButtonOrder = "button_order";
static const char* const kTopRowFormat = "top_row_format";
static const char* const kBottomRowFormat = "bottom_row_format";
static const char* const kDisplayMode = "display_mode";
static const char* const kVolumeOrientation = "volume_orientation";
static const char* const kShowVolume = "show_volume";
static const char* const kShowTrackInfo = "show_track_info";

// Default values
static const char* const kDefaultTopRowFormat = "%artist% - %title%";
static const char* const kDefaultBottomRowFormat = "%playback_time% / %length%";
static const char* const kDefaultButtonOrder = "[0,1,2,3,4,5]";

// Display modes
enum DisplayMode {
    DisplayModeFull = 0,
    DisplayModeCompact = 1
};

// Volume slider orientation
enum VolumeOrientation {
    VolumeOrientationHorizontal = 0,
    VolumeOrientationVertical = 1
};

// Button types (for ordering)
enum ButtonType {
    ButtonTypePrevious = 0,
    ButtonTypeStop = 1,
    ButtonTypePlayPause = 2,
    ButtonTypeNext = 3,
    ButtonTypeVolume = 4,
    ButtonTypeTrackInfo = 5,
    ButtonTypeCount = 6
};

// Helper functions

inline pfc::string8 getFullKey(const char* key) {
    pfc::string8 fullKey;
    fullKey << kPrefix << key;
    return fullKey;
}

inline pfc::string8 getInstanceKey(const char* instanceId, const char* key) {
    pfc::string8 fullKey;
    fullKey << kPrefix << instanceId << "." << key;
    return fullKey;
}

inline bool getConfigBool(const char* key, bool defaultVal, const char* instanceId = nullptr) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return defaultVal;
        pfc::string8 fullKey = instanceId ? getInstanceKey(instanceId, key) : getFullKey(key);
        return store->getConfigBool(fullKey.c_str(), defaultVal);
    } catch (...) {
        return defaultVal;
    }
}

inline void setConfigBool(const char* key, bool value, const char* instanceId = nullptr) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        pfc::string8 fullKey = instanceId ? getInstanceKey(instanceId, key) : getFullKey(key);
        store->setConfigBool(fullKey.c_str(), value);
    } catch (...) {
        console::error("[PlaybackControls] Failed to save config bool");
    }
}

inline int64_t getConfigInt(const char* key, int64_t defaultVal, const char* instanceId = nullptr) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return defaultVal;
        pfc::string8 fullKey = instanceId ? getInstanceKey(instanceId, key) : getFullKey(key);
        return store->getConfigInt(fullKey.c_str(), defaultVal);
    } catch (...) {
        return defaultVal;
    }
}

inline void setConfigInt(const char* key, int64_t value, const char* instanceId = nullptr) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        pfc::string8 fullKey = instanceId ? getInstanceKey(instanceId, key) : getFullKey(key);
        store->setConfigInt(fullKey.c_str(), value);
    } catch (...) {
        console::error("[PlaybackControls] Failed to save config int");
    }
}

inline std::string getConfigString(const char* key, const char* defaultVal, const char* instanceId = nullptr) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return defaultVal;
        pfc::string8 fullKey = instanceId ? getInstanceKey(instanceId, key) : getFullKey(key);
        fb2k::stringRef result = store->getConfigString(fullKey.c_str(), defaultVal);
        if (result.is_valid()) {
            return result->c_str();
        }
        return defaultVal;
    } catch (...) {
        return defaultVal;
    }
}

inline void setConfigString(const char* key, const std::string& value, const char* instanceId = nullptr) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        pfc::string8 fullKey = instanceId ? getInstanceKey(instanceId, key) : getFullKey(key);
        store->setConfigString(fullKey.c_str(), value.c_str());
    } catch (...) {
        console::error("[PlaybackControls] Failed to save config string");
    }
}

// Convenience accessors

inline std::string getButtonOrder(const char* instanceId = nullptr) {
    return getConfigString(kButtonOrder, kDefaultButtonOrder, instanceId);
}

inline void setButtonOrder(const std::string& order, const char* instanceId = nullptr) {
    setConfigString(kButtonOrder, order, instanceId);
}

inline std::string getTopRowFormat(const char* instanceId = nullptr) {
    return getConfigString(kTopRowFormat, kDefaultTopRowFormat, instanceId);
}

inline void setTopRowFormat(const std::string& format, const char* instanceId = nullptr) {
    setConfigString(kTopRowFormat, format, instanceId);
}

inline std::string getBottomRowFormat(const char* instanceId = nullptr) {
    return getConfigString(kBottomRowFormat, kDefaultBottomRowFormat, instanceId);
}

inline void setBottomRowFormat(const std::string& format, const char* instanceId = nullptr) {
    setConfigString(kBottomRowFormat, format, instanceId);
}

inline DisplayMode getDisplayMode(const char* instanceId = nullptr) {
    return static_cast<DisplayMode>(getConfigInt(kDisplayMode, DisplayModeFull, instanceId));
}

inline void setDisplayMode(DisplayMode mode, const char* instanceId = nullptr) {
    setConfigInt(kDisplayMode, static_cast<int64_t>(mode), instanceId);
}

inline VolumeOrientation getVolumeOrientation(const char* instanceId = nullptr) {
    return static_cast<VolumeOrientation>(getConfigInt(kVolumeOrientation, VolumeOrientationHorizontal, instanceId));
}

inline void setVolumeOrientation(VolumeOrientation orientation, const char* instanceId = nullptr) {
    setConfigInt(kVolumeOrientation, static_cast<int64_t>(orientation), instanceId);
}

inline bool isVolumeVisible(const char* instanceId = nullptr) {
    return getConfigBool(kShowVolume, true, instanceId);
}

inline void setVolumeVisible(bool visible, const char* instanceId = nullptr) {
    setConfigBool(kShowVolume, visible, instanceId);
}

inline bool isTrackInfoVisible(const char* instanceId = nullptr) {
    return getConfigBool(kShowTrackInfo, true, instanceId);
}

inline void setTrackInfoVisible(bool visible, const char* instanceId = nullptr) {
    setConfigBool(kShowTrackInfo, visible, instanceId);
}

} // namespace playback_controls_config
