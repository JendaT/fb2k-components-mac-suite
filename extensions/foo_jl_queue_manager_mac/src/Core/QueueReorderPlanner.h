//
//  QueueReorderPlanner.h
//  foo_jl_queue_manager
//
//  Pure move planning for drag-reorder within the playback queue.
//
//  No foobar2000 SDK dependency (size_t only) so it can be unit-tested
//  standalone. Extracted verbatim from QueueManagerController's
//  handleInternalDropAtRow: internal-drop branch.
//

#pragma once

#include <cstddef>
#include <vector>

namespace queue_reorder {

// A drop is a no-op when the item would land back where it started:
// dropping at its own slot or at the slot immediately after it.
// destRow is an "insert before this row" index (destRow == itemCount
// means end of queue).
bool isNoopMove(size_t itemCount, size_t sourceRow, size_t destRow);

// Plan moving the single item at sourceRow so it sits at destRow
// (insert-before convention, destRow clamped to itemCount). Non-moved
// items keep their relative order.
//
// Returns the new queue order as indices into the old contents:
// result[newPosition] = oldPosition, result.size() == itemCount.
// Returns an empty vector when the move is a no-op or sourceRow is out
// of range — callers skip the queue rebuild entirely in that case.
std::vector<size_t> planSingleMove(size_t itemCount, size_t sourceRow, size_t destRow);

}  // namespace queue_reorder
