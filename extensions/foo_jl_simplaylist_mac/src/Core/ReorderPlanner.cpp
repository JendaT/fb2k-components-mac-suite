//
//  ReorderPlanner.cpp
//  foo_simplaylist_mac
//
//  Pure reorder permutation — see ReorderPlanner.h.
//  Algorithm moved verbatim from SimPlaylistController; behavior unchanged.
//

#include "ReorderPlanner.h"

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

    // Flag source indices for O(1) lookup. Out-of-range entries are dropped:
    // with duplicate or >= itemCount sources the write loops below would run
    // past the end of `order` (heap overflow). Rebuilding `sources` from the
    // flags also dedupes and sorts, so it is unique, sorted and in-range from
    // here on (a flat array rather than a tree: select-all on a large playlist
    // would otherwise allocate one heap node per selected index).
    std::vector<char> isSource(itemCount, 0);
    for (size_t s : sortedSources) {
        if (s < itemCount) isSource[s] = 1;
    }
    std::vector<size_t> sources;
    for (size_t i = 0; i < itemCount; i++) {
        if (isSource[i]) sources.push_back(i);
    }

    // Calculate where items actually go after removal
    size_t adjustedDest = adjustedReorderDestination(sources, destIndex);

    // Build the order array
    // 1. Collect non-moved items in original order
    // 2. Insert moved items at the adjusted destination
    std::vector<size_t> nonMovedItems;
    for (size_t i = 0; i < itemCount; i++) {
        if (!isSource[i]) {
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
