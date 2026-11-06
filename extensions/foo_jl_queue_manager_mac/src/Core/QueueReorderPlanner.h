//
//  QueueReorderPlanner.h
//  foo_jl_queue_manager
//
//  Pure move planning for drag-reorder within the playback queue.
//
//  No foobar2000 SDK dependency (size_t only) so it can be unit-tested
//  standalone. Extracted from QueueManagerController's
//  handleInternalDropAtRow: internal-drop branch, then generalized from
//  single-row to multi-row moves (same shape as SimPlaylist's
//  ReorderPlanner).
//

#pragma once

#include <cstddef>
#include <vector>

namespace queue_reorder {

// Plan moving the items at `sortedSources` (ascending, unique queue rows)
// so they sit contiguously, in their original relative order, at
// `destRow`. destRow is an "insert before this row" index; values
// > itemCount are clamped to itemCount (end of queue). Non-moved items
// keep their relative order.
//
// Returns the new queue order as indices into the old contents:
// result[newPosition] = oldPosition, result.size() == itemCount.
// Returns an empty vector when the move changes nothing (drop back onto
// the same slot) or when the input is invalid (no sources, a source out
// of range, or sources not strictly ascending) — callers skip the queue
// rebuild entirely in that case.
std::vector<size_t> planMove(size_t itemCount,
                             const std::vector<size_t>& sortedSources,
                             size_t destRow);

}  // namespace queue_reorder
