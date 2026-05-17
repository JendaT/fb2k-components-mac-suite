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
static const char* const kCustomColumns = "custom_columns";  // User-defined column templates

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

// Hide subgroups if there's only one in the album (e.g., hide "Disc 1" if album only has Disc 1)
static const char* const kHideSingleSubgroup = "hide_single_subgroup";

// Display size: 0 = compact (smaller), 1 = normal (default), 2 = large
static const char* const kDisplaySize = "display_size";

// Column header bar size: 0 = compact, 1 = normal (default), 2 = large
static const char* const kColumnHeaderSize = "column_header_size";

// Column header accent color: 0 = none, 1 = tinted
static const char* const kHeaderAccentColor = "header_accent_color";

// Glass (transparent) background - allows content behind to show through
static const char* const kGlassBackground = "glass_background";

// Group header spacing: 0 = normal (4px symmetrical), 1 = larger (7px symmetrical)
static const char* const kGroupHeaderSpacing = "group_header_spacing";

// Debug rendering: show diagnostic text on rendering anomalies
static const char* const kDebugRendering = "debug_rendering";

// Last playing track persistence (restored on startup)
static const char* const kLastPlayingPlaylist = "last_playing_playlist";
static const char* const kLastPlayingPath = "last_playing_path";

// Drag to Finder: move files by default (instead of copy)
static const char* const kDragToFinderMove = "drag_to_finder_move";

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
static const bool kDefaultHideSingleSubgroup = false;  // Don't hide single subgroups by default
static const int64_t kDefaultDisplaySize = 1;  // 0=compact, 1=normal, 2=large
static const int64_t kDefaultColumnHeaderSize = 1;  // 0=compact, 1=normal, 2=large
static const int64_t kDefaultHeaderAccentColor = 0;  // 0=none, 1=tinted
static const bool kDefaultGlassBackground = false;   // Opaque background by default
static const int64_t kDefaultGroupHeaderSpacing = 1; // 0=compact, 1=normal, 2=larger
static const bool kDefaultDebugRendering = false;     // Hide debug diagnostics by default
static const bool kDefaultDragToFinderMove = false;   // Copy files by default when dragging to Finder

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
        FB2K_console_formatter() << "[SimPlaylist] Config read error for key: " << key;
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
        FB2K_console_formatter() << "[SimPlaylist] Config write error for key: " << key;
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
        FB2K_console_formatter() << "[SimPlaylist] Config read error for key: " << key;
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
        FB2K_console_formatter() << "[SimPlaylist] Config write error for key: " << key;
    }
}

// Default group presets JSON
inline const char* getDefaultGroupPresetsJSON() {
    return R"JSON({
  "presets": [
    {
      "name": "Artist - album / cover",
      "sorting_pattern": "%path_sort%",
      "header": {
        "pattern": "[%album artist% - ]['['$year(%date%)']' ][%album%]",
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

// Default custom columns JSON (empty array)
inline const char* getDefaultCustomColumnsJSON() {
    return R"JSON({
  "columns": []
})JSON";
}

// Sanitize playlist name for use as a config key component.
// Replaces non-alphanumeric/underscore/dash chars with '_', truncates to 64 chars.
inline std::string sanitizePlaylistName(const char* name) {
    if (!name) return "";
    std::string result;
    result.reserve(64);
    for (const char* p = name; *p && result.size() < 64; ++p) {
        char c = *p;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '-') {
            result += c;
        } else {
            result += '_';
        }
    }
    return result;
}

// Build a config key for storing group cache for a playlist.
// Returns "group_cache.<sanitized_name>"
inline std::string groupCacheKey(const char* playlistName) {
    return std::string("group_cache.") + sanitizePlaylistName(playlistName);
}

} // namespace simplaylist_config
