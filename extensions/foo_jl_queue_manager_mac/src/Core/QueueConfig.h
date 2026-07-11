//
//  QueueConfig.h
//  foo_jl_queue_manager
//
//  Configuration constants and defaults for Queue Manager
//

#pragma once

#include <cstring>

namespace queue_config {

// Config keys
static const char* const kKeyVisibleColumns = "visible_columns";
static const char* const kKeyColumnWidthsJson = "column_widths_json";
static const char* const kKeyTransparentBackground = "transparent_background";

// Default values
static const char* const kDefaultVisibleColumns = "queue_index,artist_title,duration";
static const char* const kDefaultColumnWidthsJson = "{}";
static const bool kDefaultTransparentBackground = true;

// Column identifiers
static const char* const kColumnQueueIndex = "queue_index";
static const char* const kColumnArtistTitle = "artist_title";
static const char* const kColumnArtist = "artist";
static const char* const kColumnTitle = "title";
static const char* const kColumnAlbum = "album";
static const char* const kColumnDuration = "duration";
static const char* const kColumnCodec = "codec";

// Single source of truth for column metadata. The controller builds its
// NSTableColumns from this table and QueueItemWrapper takes its title
// format from it; do not re-hardcode identifiers/titles/widths elsewhere.
struct ColumnInfo {
    const char* identifier;
    const char* displayName;
    const char* titleFormat;   // nullptr = value computed by the view (queue #)
    int defaultWidth;
    int minWidth;
    int maxWidth;              // 0 = no maximum
    bool flexible;             // takes horizontal autoresizing slack
};

// Available columns (queue_index/artist_title/duration are the Phase 1
// defaults; the rest await the Phase 4 column picker)
static const ColumnInfo kAvailableColumns[] = {
    { kColumnQueueIndex,  "#",              nullptr,                       30,  30,  50, false },
    { kColumnArtistTitle, "Artist - Title", "[%artist% - ]%title%",       200, 100,   0, true  },
    { kColumnArtist,      "Artist",         "%artist%",                   120,  60,   0, true  },
    { kColumnTitle,       "Title",          "%title%",                    150,  60,   0, true  },
    { kColumnAlbum,       "Album",          "%album%",                    150,  60,   0, true  },
    { kColumnDuration,    "Duration",       "%length%",                    60,  50,  80, false },
    { kColumnCodec,       "Codec",          "%codec%",                     80,  50, 120, false },
};

static const size_t kAvailableColumnsCount = sizeof(kAvailableColumns) / sizeof(kAvailableColumns[0]);

// Look up a column by identifier; nullptr if unknown.
inline const ColumnInfo* findColumn(const char* identifier) {
    for (size_t i = 0; i < kAvailableColumnsCount; i++) {
        if (std::strcmp(kAvailableColumns[i].identifier, identifier) == 0) {
            return &kAvailableColumns[i];
        }
    }
    return nullptr;
}

// Orphan item sentinel value (item not from any playlist)
static const size_t kOrphanPlaylistIndex = ~(size_t)0;

// UI sizing (uses shared styles from UIStyles.h for actual values)
static const int kMinWidth = 150;
static const int kMinHeight = 100;
static const int kStatusBarHeight = 22;
// Note: Row/header heights now use fb2k_ui::rowHeight() and fb2k_ui::headerHeight() functions

} // namespace queue_config
