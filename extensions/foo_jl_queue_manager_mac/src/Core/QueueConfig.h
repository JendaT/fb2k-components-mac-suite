//
//  QueueConfig.h
//  foo_jl_queue_manager
//
//  Configuration constants and defaults for Queue Manager
//

#pragma once

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

// Column display names
struct ColumnInfo {
    const char* identifier;
    const char* displayName;
    const char* titleFormat;
    int defaultWidth;
    bool isResizable;
};

// Available columns (used for Phase 4 column picker)
static const ColumnInfo kAvailableColumns[] = {
    { kColumnQueueIndex,  "#",              nullptr,                       30,  false },
    { kColumnArtistTitle, "Artist - Title", "[%artist% - ]%title%",       200, true  },
    { kColumnArtist,      "Artist",         "%artist%",                   120, true  },
    { kColumnTitle,       "Title",          "%title%",                    150, true  },
    { kColumnAlbum,       "Album",          "%album%",                    150, true  },
    { kColumnDuration,    "Duration",       "%length%",                    60, false },
    { kColumnCodec,       "Codec",          "%codec%",                     80, false },
};

static const size_t kAvailableColumnsCount = sizeof(kAvailableColumns) / sizeof(kAvailableColumns[0]);

// UI sizing (uses shared styles from UIStyles.h for actual values)
static const int kMinWidth = 150;
static const int kMinHeight = 100;
static const int kStatusBarHeight = 22;
// Note: kRowHeight moved to shared/UIStyles.h as fb2k_ui::kDefaultRowHeight

} // namespace queue_config
