//
//  ConfigHelper.h
//  foo_jl_libvanced
//
//  Configuration persistence via fb2k::configStore
//

#pragma once
#include "../fb2k_sdk.h"
#include <string>

namespace libvanced_config {

static const char* const kPrefix = "foo_libvanced_mac.";

// Tree grouping pattern keys
static const char* const kGroupPattern = "group_pattern";
static const char* const kSortPattern = "sort_pattern";
static const char* const kFilterQuery = "filter_query";

// Appearance
static const char* const kRowHeight = "row_height";
static const char* const kShowAlbumArt = "show_album_art";
static const char* const kAlbumArtSize = "album_art_size";
static const char* const kShowTrackCount = "show_track_count";
static const char* const kGlassBackground = "glass_background";

// Behavior
static const char* const kDoubleClickAction = "double_click_action";
static const char* const kExpandOnSelect = "expand_on_select";

// Defaults
static const int64_t kDefaultRowHeight = 22;
static const bool kDefaultShowAlbumArt = true;
static const int64_t kDefaultAlbumArtSize = 32;
static const bool kDefaultShowTrackCount = true;
static const bool kDefaultGlassBackground = false;
static const int64_t kDefaultDoubleClickAction = 0; // 0=send to playlist, 1=add to queue
static const bool kDefaultExpandOnSelect = false;

inline std::string getDefaultGroupPattern() {
    return "%album artist%|[%date% - ]%album%";
}

inline std::string getDefaultSortPattern() {
    return "%album artist% | %date% | %album% | %discnumber% | %tracknumber%";
}

// Helper functions
inline std::string getFullKey(const char* key) {
    return std::string(kPrefix) + key;
}

inline int64_t getConfigInt(const char* key, int64_t defaultValue) {
    try {
        auto store = fb2k::configStore::get();
        if (store.is_valid()) {
            return store->getConfigInt(getFullKey(key).c_str(), defaultValue);
        }
    } catch (...) {
        FB2K_console_formatter() << "[LibVanced] Config read error for key: " << key;
    }
    return defaultValue;
}

inline void setConfigInt(const char* key, int64_t value) {
    try {
        auto store = fb2k::configStore::get();
        if (store.is_valid()) {
            store->setConfigInt(getFullKey(key).c_str(), value);
        }
    } catch (...) {
        FB2K_console_formatter() << "[LibVanced] Config write error for key: " << key;
    }
}

inline bool getConfigBool(const char* key, bool defaultValue) {
    return getConfigInt(key, defaultValue ? 1 : 0) != 0;
}

inline void setConfigBool(const char* key, bool value) {
    setConfigInt(key, value ? 1 : 0);
}

inline std::string getConfigString(const char* key, const char* defaultValue) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) {
            return defaultValue ? defaultValue : "";
        }

        fb2k::stringRef result = store->getConfigString(getFullKey(key).c_str(), nullptr);

        if (!result.is_valid() || result.get_ptr() == nullptr) {
            return defaultValue ? defaultValue : "";
        }

        const char* cstr = result->c_str();
        if (cstr != nullptr && cstr[0] != '\0') {
            return std::string(cstr);
        }
    } catch (...) {
        FB2K_console_formatter() << "[LibVanced] Config read error for key: " << key;
    }
    return defaultValue ? defaultValue : "";
}

inline void setConfigString(const char* key, const char* value) {
    try {
        auto store = fb2k::configStore::get();
        if (store.is_valid()) {
            store->setConfigString(getFullKey(key).c_str(), value);
        }
    } catch (...) {
        FB2K_console_formatter() << "[LibVanced] Config write error for key: " << key;
    }
}

} // namespace libvanced_config
