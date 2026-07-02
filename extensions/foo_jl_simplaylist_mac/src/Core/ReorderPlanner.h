//
//  ReorderPlanner.h
//  foo_simplaylist_mac
//
//  Pure permutation planning for drag-reorder within a playlist.
//
//  No foobar2000 SDK dependency (size_t instead of t_size) so it can be
//  unit-tested standalone. Extracted verbatim from
//  SimPlaylistController's didReorderRows: MOVE branch.
//

#pragma once

#include <cstddef>
#include <vector>

namespace simplaylist {

// Plan a reorder that moves `sortedSources` (ascending playlist indices,
// all < itemCount) so they sit contiguously, in their original relative
// order, at `destIndex` (interpreted as "insert before this playlist index";
// values >= itemCount mean end-of-list). Non-moved items keep their relative
// order.
//
// Returns the permutation in playlist_reorder_items() convention:
// result[newPosition] = oldPosition, with result.size() == itemCount.
std::vector<size_t> planReorder(size_t itemCount,
                                const std::vector<size_t> &sortedSources,
                                size_t destIndex);

// The destination slot after accounting for moved items that sit before it:
// destIndex minus the number of sources < destIndex. This is where the moved
// block starts in the reordered list (exposed for focus/selection placement).
size_t adjustedReorderDestination(const std::vector<size_t> &sortedSources,
                                  size_t destIndex);

}  // namespace simplaylist
