//
//  QueuePersistence.h
//  foo_jl_queue_manager
//
//  Serialization of the playback queue for restore across restarts.
//  Pure C++ (no SDK) so it compiles and tests standalone.
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace queue_persist {

// Playlist value for entries not tied to a playlist position
static const size_t kNoPlaylist = ~(size_t)0;

struct SavedEntry {
    std::string path;        // metadb location path
    uint32_t subsong = 0;
    size_t playlist = kNoPlaylist;  // source playlist, kNoPlaylist if orphan
    size_t item = 0;         // index in source playlist (ignored for orphans)

    bool operator==(const SavedEntry& o) const {
        return path == o.path && subsong == o.subsong &&
               playlist == o.playlist && (playlist == kNoPlaylist || item == o.item);
    }
};

// Serialize entries to a versioned, line-based text blob.
std::string serialize(const std::vector<SavedEntry>& entries);

// Parse a blob produced by serialize(). Unknown versions yield an empty
// list; malformed lines are skipped so one bad entry never loses the rest.
std::vector<SavedEntry> deserialize(const std::string& blob);

} // namespace queue_persist
