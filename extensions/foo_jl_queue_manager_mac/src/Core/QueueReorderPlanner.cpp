//
//  QueueReorderPlanner.cpp
//  foo_jl_queue_manager
//
//  Pure multi-item move planning — see QueueReorderPlanner.h.
//

#include "QueueReorderPlanner.h"

namespace queue_reorder {

std::vector<size_t> planMove(size_t itemCount,
                             const std::vector<size_t>& sortedSources,
                             size_t destRow) {
    if (sortedSources.empty()) return {};
    if (destRow > itemCount) destRow = itemCount;

    // Validate: strictly ascending, all in range.
    for (size_t i = 0; i < sortedSources.size(); i++) {
        if (sortedSources[i] >= itemCount) return {};
        if (i > 0 && sortedSources[i] <= sortedSources[i - 1]) return {};
    }

    // The insertion slot after the moved items are removed from the list:
    // destRow minus the number of sources that sat before it.
    size_t adjustedDest = destRow;
    for (size_t s : sortedSources) {
        if (s < destRow) adjustedDest--;
    }

    // Non-moved items in original order. sortedSources is ascending, so a
    // single cursor suffices to skip them.
    std::vector<size_t> nonMoved;
    nonMoved.reserve(itemCount - sortedSources.size());
    size_t nextSource = 0;
    for (size_t i = 0; i < itemCount; i++) {
        if (nextSource < sortedSources.size() && sortedSources[nextSource] == i) {
            nextSource++;
        } else {
            nonMoved.push_back(i);
        }
    }

    std::vector<size_t> order;
    order.reserve(itemCount);
    order.insert(order.end(), nonMoved.begin(), nonMoved.begin() + adjustedDest);
    order.insert(order.end(), sortedSources.begin(), sortedSources.end());
    order.insert(order.end(), nonMoved.begin() + adjustedDest, nonMoved.end());

    // A plan that reproduces the current order is a no-op; signal it with
    // an empty result so callers skip the flush-and-readd entirely.
    bool identity = true;
    for (size_t i = 0; i < itemCount; i++) {
        if (order[i] != i) { identity = false; break; }
    }
    if (identity) return {};

    return order;
}

}  // namespace queue_reorder
