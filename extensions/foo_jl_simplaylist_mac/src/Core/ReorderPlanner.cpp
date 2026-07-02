//
//  ReorderPlanner.cpp
//  foo_simplaylist_mac
//
//  Pure reorder permutation — see ReorderPlanner.h.
//  Algorithm moved verbatim from SimPlaylistController; behavior unchanged.
//

#include "ReorderPlanner.h"

#include <set>

namespace simplaylist {

size_t adjustedReorderDestination(const std::vector<size_t> &sortedSources,
                                  size_t destIndex) {
    size_t adjustedDest = destIndex;
    for (size_t s : sortedSources) {
        if (s < destIndex) {
            adjustedDest--;
        }
    }
    return adjustedDest;
}

std::vector<size_t> planReorder(size_t itemCount,
                                const std::vector<size_t> &sortedSources,
                                size_t destIndex) {
    std::vector<size_t> order(itemCount);

    // Create a set of source indices for quick lookup
    std::set<size_t> sourceSet(sortedSources.begin(), sortedSources.end());

    // Calculate where items actually go after removal
    size_t adjustedDest = adjustedReorderDestination(sortedSources, destIndex);

    // Build the order array
    // 1. Collect non-moved items in original order
    // 2. Insert moved items at the adjusted destination
    std::vector<size_t> nonMovedItems;
    for (size_t i = 0; i < itemCount; i++) {
        if (sourceSet.find(i) == sourceSet.end()) {
            nonMovedItems.push_back(i);
        }
    }

    // Build final order: non-moved items with moved items inserted at adjustedDest
    size_t writePos = 0;

    // Items before destination
    for (size_t i = 0; i < adjustedDest && i < nonMovedItems.size(); i++) {
        order[writePos++] = nonMovedItems[i];
    }

    // Insert moved items at destination
    for (size_t s : sortedSources) {
        order[writePos++] = s;
    }

    // Items after destination
    for (size_t i = adjustedDest; i < nonMovedItems.size(); i++) {
        order[writePos++] = nonMovedItems[i];
    }

    return order;
}

}  // namespace simplaylist
