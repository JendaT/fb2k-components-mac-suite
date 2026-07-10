//
//  QueueReorderPlanner.cpp
//  foo_jl_queue_manager
//
//  Pure single-item move planning — see QueueReorderPlanner.h.
//  Algorithm moved from QueueManagerController; behavior unchanged.
//

#include "QueueReorderPlanner.h"

namespace queue_reorder {

bool isNoopMove(size_t itemCount, size_t sourceRow, size_t destRow) {
    if (destRow > itemCount) destRow = itemCount;
    return sourceRow == destRow || sourceRow + 1 == destRow;
}

std::vector<size_t> planSingleMove(size_t itemCount, size_t sourceRow, size_t destRow) {
    if (sourceRow >= itemCount) return {};
    if (destRow > itemCount) destRow = itemCount;
    if (isNoopMove(itemCount, sourceRow, destRow)) return {};

    // The insertion slot after the source item is removed from the list.
    size_t adjustedDest = (sourceRow < destRow) ? destRow - 1 : destRow;

    std::vector<size_t> order;
    order.reserve(itemCount);

    for (size_t i = 0; i < itemCount; i++) {
        if (i == sourceRow) continue;
        if (order.size() == adjustedDest) {
            order.push_back(sourceRow);
        }
        order.push_back(i);
    }
    // Moved item lands at the end.
    if (order.size() < itemCount) {
        order.push_back(sourceRow);
    }

    return order;
}

}  // namespace queue_reorder
