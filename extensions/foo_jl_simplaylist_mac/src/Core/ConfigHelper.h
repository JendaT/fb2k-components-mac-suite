//
//  ConfigHelper.h
//  foo_simplaylist_mac
//
//  Configuration persistence via fb2k::configStore
//

#pragma once
#include "../fb2k_sdk.h"
#include <string>

namespace simplaylist_config {

// Config key prefix
static const char* const kPrefix = "foo_simplaylist_mac.";

// Group configuration keys
static const char* const kGroupPresets = "group_presets";
static const char* const kActivePresetIndex = "active_preset_index";

// Column configuration keys
static const char* const kColumns = "columns";
static const char* const kColumnOrder = "column_order";

// Appearance keys
static const char* const kRowHeight = "row_height";
static const char* const kHeaderHeight = "header_height";
static const char* const kSubgroupHeight = "subgroup_height";
static const char* const kGroupColumnWidth = "group_column_width";
static const char* const kAlbumArtSize = "album_art_size";
static const char* const kShowRowNumbers = "show_row_numbers";

// Behavior keys
static const char* const kSmoothScrolling = "smooth_scrolling";
static const char* const kNowPlayingShading = "now_playing_shading";

// Header display style: 0 = above tracks (current), 1 = album art aligned, 2 = inline (no header row)
static const char* const kHeaderDisplayStyle = "header_display_style";

// Show first subgroup header (e.g., "Disc 1" even when there's only one disc)
static const char* const kShowFirstSubgroupHeader = "show_first_subgroup_header";

// Dim text in parentheses (both () and [])
static const char* const kDimParentheses = "dim_parentheses";

// Default values - row heights sized for 13pt font
static const int64_t kDefaultRowHeight = 22;
static const int64_t kDefaultHeaderHeight = 28;
static const int64_t kDefaultSubgroupHeight = 24;
static const int64_t kDefaultGroupColumnWidth = 80;  // Album art column width
static const int64_t kDefaultAlbumArtSize = 64;      // Album art size in pixels
static const bool kDefaultShowRowNumbers = false;
static const bool kDefaultSmoothScrolling = true;
static const bool kDefaultNowPlayingShading = true;
static const int64_t kDefaultHeaderDisplayStyle = 0;  // 0 = above tracks
static const bool kDefaultShowFirstSubgroupHeader = true;  // Show "Disc 1" etc.
static const bool kDefaultDimParentheses = true;  // Dim text in () and []

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
    } catch (...) {}
    return defaultValue;
}

inline void setConfigInt(const char* key, int64_t value) {
    try {
        auto store = fb2k::configStore::get();
        if (store.is_valid()) {
            store->setConfigInt(getFullKey(key).c_str(), value);
        }
    } catch (...) {}
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

        // Pass nullptr as default to detect if key exists
        fb2k::stringRef result = store->getConfigString(getFullKey(key).c_str(), nullptr);

        // Defensive: check validity before any access
        if (!result.is_valid() || result.get_ptr() == nullptr) {
            return defaultValue ? defaultValue : "";
        }

        // Safe access with additional null check
        const char* cstr = result->c_str();
        if (cstr != nullptr && cstr[0] != '\0') {
            return std::string(cstr);
        }
    } catch (...) {
        // Silently handle any exceptions
    }
    return defaultValue ? defaultValue : "";
}

inline void setConfigString(const char* key, const char* value) {
    try {
        auto store = fb2k::configStore::get();
        if (store.is_valid()) {
            store->setConfigString(getFullKey(key).c_str(), value);
        }
    } catch (...) {}
}

// Default group presets JSON
inline const char* getDefaultGroupPresetsJSON() {
    return R"JSON({
  "presets": [
    {
      "name": "Artist - album / cover",
      "sorting_pattern": "%path_sort%",
      "header": {
        "pattern": "[%album artist% - ]['['%date%']' ][%album%]",
        "display": "text"
      },
      "group_column": {
        "pattern": "[%album%]",
        "display": "front"
      },
      "subgroups": [
        {
          "pattern": "[Disc %discnumber%]",
          "display": "text"
        }
      ]
    },
    {
      "name": "Album",
      "sorting_pattern": "%path_sort%",
      "header": {
        "pattern": "[%album%]",
        "display": "text"
      },
      "group_column": {
        "pattern": "[%album%]",
        "display": "front"
      },
      "subgroups": [
        {
          "pattern": "[Disc %discnumber%]",
          "display": "text"
        }
      ]
    }
  ],
  "active_index": 0
})JSON";
}

// Default columns JSON
inline const char* getDefaultColumnsJSON() {
    return R"JSON({
  "columns": [
    {"name": "Playing", "pattern": "$if(%isplaying%,>,)", "width": 24, "alignment": "center"},
    {"name": "#", "pattern": "%tracknumber%", "width": 32, "alignment": "right"},
    {"name": "Title", "pattern": "%title%", "width": 250, "alignment": "left", "auto_resize": true},
    {"name": "Artist", "pattern": "%artist%", "width": 150, "alignment": "left", "auto_resize": true},
    {"name": "Duration", "pattern": "%length%", "width": 50, "alignment": "right"}
  ]
})JSON";
}

} // namespace simplaylist_config
