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
    // Count DISTINCT sources below destIndex (skipping adjacent duplicates in
    // the sorted input): at most destIndex distinct values are < destIndex, so
    // the subtraction cannot underflow even for callers that bypass
    // planReorder's dedupe. The final clamp covers unsorted misuse too.
    size_t removedBelow = 0;
    bool havePrev = false;
    size_t prev = 0;
    for (size_t s : sortedSources) {
        if (s < destIndex && (!havePrev || s != prev)) {
            removedBelow++;
        }
        prev = s;
        havePrev = true;
    }
    if (removedBelow > destIndex) removedBelow = destIndex;
    return destIndex - removedBelow;
}

std::vector<size_t> planReorder(size_t itemCount,
                                const std::vector<size_t> &sortedSources,
                                size_t destIndex) {
    std::vector<size_t> order(itemCount);

    // Create a set of source indices for quick lookup. Out-of-range entries
    // are dropped: with duplicate or >= itemCount sources the write loops
    // below would run past the end of `order` (heap overflow). The set also
    // dedupes, so `sources` is unique, sorted and in-range from here on.
    std::set<size_t> sourceSet;
    for (size_t s : sortedSources) {
        if (s < itemCount) sourceSet.insert(s);
    }
    std::vector<size_t> sources(sourceSet.begin(), sourceSet.end());

    // Calculate where items actually go after removal
    size_t adjustedDest = adjustedReorderDestination(sources, destIndex);

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
    for (size_t s : sources) {
        order[writePos++] = s;
    }

    // Items after destination
    for (size_t i = adjustedDest; i < nonMovedItems.size(); i++) {
        order[writePos++] = nonMovedItems[i];
    }

    return order;
}

}  // namespace simplaylist
