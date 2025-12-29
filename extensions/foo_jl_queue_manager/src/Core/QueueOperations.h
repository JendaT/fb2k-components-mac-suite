//
//  QueueOperations.h
//  foo_jl_queue_manager
//
//  Wrapper for SDK queue operations
//  All operations are thread-safe and run on main thread
//

#pragma once

#include <foobar2000/SDK/foobar2000.h>
#include <vector>

namespace queue_ops {

// Get number of items in queue
size_t getCount();

// Get all queue contents
void getContents(pfc::list_base_t<t_playback_queue_item>& out);

// Get queue contents as std::vector (convenience)
std::vector<t_playback_queue_item> getContentsVector();

// Remove items at specified indices (indices must be sorted ascending)
void removeItems(const std::vector<size_t>& indices);

// Remove item at single index
void removeItem(size_t index);

// Clear entire queue
void clear();

// Add item from playlist to queue
void addItemFromPlaylist(size_t playlist, size_t item);

// Add orphan item (not associated with any playlist)
void addOrphanItem(metadb_handle_ptr handle);

// Check if a queue item is still valid (playlist/item references are current)
bool isItemValid(const t_playback_queue_item& item);

// Check if item is an orphan (not from a playlist)
bool isOrphanItem(const t_playback_queue_item& item);

// Play a queue item (starts playback)
// Returns true if playback was started successfully
bool playItem(const t_playback_queue_item& item);

// Format a queue item for display using title format script
pfc::string8 formatItem(const t_playback_queue_item& item, const char* formatString);

// Format queue item duration as string (e.g., "3:45")
pfc::string8 formatDuration(const t_playback_queue_item& item);

} // namespace queue_ops
