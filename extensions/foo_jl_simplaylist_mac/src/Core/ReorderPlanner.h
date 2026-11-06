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

// Plan reversing the items at `positions` among themselves, leaving every
// other item where it is: the item at the first listed position swaps with the
// one at the last, and so on inward. Pass every index to reverse the whole
// playlist, or the selected indices to reverse just the selection (the
// Sort > Reverse command).
//
// `positions` is sanitised rather than trusted: it is sorted, duplicates are
// dropped, and indices >= itemCount are ignored, so a stale selection cannot
// produce an invalid permutation.
//
// Returns the permutation in playlist_reorder_items() convention:
// result[newPosition] = oldPosition, with result.size() == itemCount.
std::vector<size_t> planReverse(size_t itemCount, std::vector<size_t> positions);

}  // namespace simplaylist
