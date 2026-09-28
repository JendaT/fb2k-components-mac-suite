//
//  ReorderPlannerTests.cpp
//  foo_simplaylist_mac
//
//  Unit tests for ReorderPlanner (drag-reorder permutation).
//
//  Ground truth is a naive simulation: remove the source items from the list,
//  then insert them (in original order) at the adjusted destination. The
//  planner's permutation applied to the identity list must equal it.
//  Pure C++, compiled standalone; run as a gating phase by Scripts/build.sh.
//

#include "../src/Core/ReorderPlanner.h"
#include "TestHarness.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <set>
#include <string>
#include <vector>

// Naive ground truth: literally remove then insert. The insert position is
// derived independently of adjustedReorderDestination (the function under
// test): "insert before original index destIndex" means the moved block goes
// after every remaining item whose original index is below destIndex.
static std::vector<size_t> simulateMove(size_t itemCount,
                                        const std::vector<size_t> &sortedSources,
                                        size_t destIndex) {
    std::set<size_t> sourceSet(sortedSources.begin(), sortedSources.end());
    std::vector<size_t> remaining;
    for (size_t i = 0; i < itemCount; i++) {
        if (!sourceSet.count(i)) remaining.push_back(i);
    }
    size_t insertPos = 0;
    for (size_t v : remaining) {
        if (v < destIndex) insertPos++;
    }
    std::vector<size_t> result(remaining.begin(), remaining.begin() + insertPos);
    result.insert(result.end(), sortedSources.begin(), sortedSources.end());
    result.insert(result.end(), remaining.begin() + insertPos, remaining.end());
    return result;
}

static std::string describe(const std::vector<size_t> &v) {
    std::string s = "[";
    for (size_t i = 0; i < v.size(); i++) {
        if (i) s += ",";
        s += std::to_string(v[i]);
    }
    return s + "]";
}

static void checkCase(size_t itemCount, const std::vector<size_t> &sources,
                      size_t dest, const char *name) {
    g_checks++;
    std::vector<size_t> got = simplaylist::planReorder(itemCount, sources, dest);
    std::vector<size_t> want = simulateMove(itemCount, sources, dest);
    if (got != want) {
        g_failures++;
        printf("FAIL [%s] N=%zu sources=%s dest=%zu:\n  got  %s\n  want %s\n",
               name, itemCount, describe(sources).c_str(), dest,
               describe(got).c_str(), describe(want).c_str());
        return;
    }
    // Sanity: result is a permutation of 0..N-1
    g_checks++;
    std::vector<size_t> sorted = got;
    std::sort(sorted.begin(), sorted.end());
    for (size_t i = 0; i < sorted.size(); i++) {
        if (sorted[i] != i) {
            g_failures++;
            printf("FAIL [%s] result is not a permutation: %s\n", name, describe(got).c_str());
            return;
        }
    }
}

// Direct unit check on adjustedReorderDestination with a hand-computed
// expectation (not derived from the implementation).
static void checkAdjustedDest(const std::vector<size_t> &sources, size_t dest,
                              size_t want, const char *name) {
    g_checks++;
    size_t got = simplaylist::adjustedReorderDestination(sources, dest);
    if (got != want) {
        g_failures++;
        printf("FAIL [%s] adjustedReorderDestination(%s, %zu): got %zu want %zu\n",
               name, describe(sources).c_str(), dest, got, want);
    }
}

// Hostile/degenerate input: planReorder must sanitize (dedupe, drop
// out-of-range) and produce the same plan as the clean equivalent, never
// running past the end of the order array.
static void checkHostileCase(size_t itemCount, const std::vector<size_t> &rawSources,
                             size_t dest, const char *name) {
    std::set<size_t> sanitized;
    for (size_t s : rawSources) {
        if (s < itemCount) sanitized.insert(s);
    }
    std::vector<size_t> clean(sanitized.begin(), sanitized.end());
    g_checks++;
    std::vector<size_t> got = simplaylist::planReorder(itemCount, rawSources, dest);
    std::vector<size_t> want = simulateMove(itemCount, clean, dest);
    if (got != want) {
        g_failures++;
        printf("FAIL [%s] N=%zu raw=%s dest=%zu:\n  got  %s\n  want %s\n",
               name, itemCount, describe(rawSources).c_str(), dest,
               describe(got).c_str(), describe(want).c_str());
    }
}

// Deterministic PRNG so failures are reproducible.
static uint64_t g_rng = 0xC0FFEE;
static uint64_t nextRand() {
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 7;
    g_rng ^= g_rng << 17;
    return g_rng;
}

// Naive ground truth for planReverse: pull the items at the (sanitised)
// positions out, reverse that list, and write it back into the same slots.
static std::vector<size_t> simulateReverse(size_t itemCount, std::vector<size_t> positions) {
    std::set<size_t> uniq;
    for (size_t p : positions) if (p < itemCount) uniq.insert(p);
    std::vector<size_t> slots(uniq.begin(), uniq.end());
    std::vector<size_t> list(itemCount);
    for (size_t i = 0; i < itemCount; i++) list[i] = i;
    std::vector<size_t> picked;
    for (size_t s : slots) picked.push_back(list[s]);
    std::reverse(picked.begin(), picked.end());
    for (size_t k = 0; k < slots.size(); k++) list[slots[k]] = picked[k];
    return list;
}

static void checkReverse(size_t n, const std::vector<size_t> &positions, const char *what) {
    std::vector<size_t> got = simplaylist::planReverse(n, positions);
    std::vector<size_t> want = simulateReverse(n, positions);
    g_checks++;
    if (got != want) {
        g_failures++;
        printf("FAIL [reverse] %s (n=%zu, %zu positions)\n", what, n, positions.size());
    }
    // Always a valid permutation of 0..n-1, whatever the input.
    std::vector<size_t> sorted = got;
    std::sort(sorted.begin(), sorted.end());
    bool perm = sorted.size() == n;
    for (size_t i = 0; perm && i < n; i++) perm = (sorted[i] == i);
    CHECK(perm, "reverse yields a permutation");
}

int main() {
    // Hand-built edge cases
    checkCase(5, {1}, 4, "single forward");
    checkCase(5, {3}, 0, "single backward");
    checkCase(5, {1}, 1, "no-op same place");
    checkCase(5, {1}, 2, "insert right after self");
    checkCase(6, {1, 3, 5}, 0, "scattered to front");
    checkCase(6, {0, 1, 2}, 6, "block to end");
    checkCase(6, {0, 5}, 3, "ends to middle");
    checkCase(4, {0, 1, 2, 3}, 2, "move everything");
    checkCase(1, {0}, 1, "one item to end");
    checkCase(5, {}, 3, "empty sources = identity");
    checkCase(5, {2}, 5, "dest at end (itemCount)");
    checkCase(7, {2, 3}, 3, "dest inside the moved block");

    // adjustedReorderDestination directly: dest minus distinct sources below it
    checkAdjustedDest({}, 5, 5, "no sources");
    checkAdjustedDest({0}, 5, 4, "one below");
    checkAdjustedDest({1, 2}, 2, 1, "one of two below");
    checkAdjustedDest({3, 4}, 2, 2, "none below");
    checkAdjustedDest({0, 1, 2}, 3, 0, "all below");
    checkAdjustedDest({2}, 0, 0, "dest zero");
    checkAdjustedDest({1, 1, 1}, 3, 2, "duplicates counted once");
    checkAdjustedDest({0, 0, 0}, 1, 0, "duplicates must not underflow");

    // Hostile/degenerate planReorder inputs (heap-overflow guard coverage):
    // duplicates, out-of-range sources, dest far past the end
    checkHostileCase(5, {2, 2, 3}, 4, "duplicate sources");
    checkHostileCase(5, {7, 8}, 2, "all sources out of range");
    checkHostileCase(5, {1, 100, 1}, 9, "mixed junk, huge dest");
    checkHostileCase(3, {0, 1, 2, 0, 1, 2}, 1, "everything duplicated");
    checkHostileCase(4, {3, 3}, 100, "dup at tail, dest past end");

    // Randomized sweep: every subset size, dest across full range incl. end
    for (int iter = 0; iter < 2000; iter++) {
        size_t n = 1 + nextRand() % 30;
        std::vector<size_t> sources;
        for (size_t i = 0; i < n; i++) {
            if (nextRand() % 3 == 0) sources.push_back(i);
        }
        size_t dest = nextRand() % (n + 1);  // 0..n inclusive (n = end)
        checkCase(n, sources, dest, "random");
    }

    // --- planReverse ---
    g_context = "reverse";
    {
        std::vector<size_t> all = {0, 1, 2, 3, 4};
        std::vector<size_t> got = simplaylist::planReverse(5, all);
        CHECK((got == std::vector<size_t>{4, 3, 2, 1, 0}), "whole list reversed");
        CHECK((simplaylist::planReverse(5, {}) == std::vector<size_t>{0, 1, 2, 3, 4}),
              "no positions is the identity");
        CHECK((simplaylist::planReverse(5, {1, 3}) == std::vector<size_t>{0, 3, 2, 1, 4}),
              "only the selected slots swap; the item between them stays");
        CHECK((simplaylist::planReverse(5, {2}) == std::vector<size_t>{0, 1, 2, 3, 4}),
              "a single selected item stays put");
        CHECK(simplaylist::planReverse(0, {}).empty(), "empty playlist");
        // Reversal is its own inverse: applying the permutation twice restores order.
        std::vector<size_t> once = simplaylist::planReverse(6, {0, 2, 3, 5});
        std::vector<size_t> twice(6);
        for (size_t i = 0; i < 6; i++) twice[i] = once[once[i]];
        CHECK((twice == std::vector<size_t>{0, 1, 2, 3, 4, 5}), "reverse twice is the identity");
    }
    // Hostile input: unsorted, duplicated and out-of-range positions (a stale selection).
    checkReverse(5, {3, 1}, "unsorted");
    checkReverse(5, {1, 1, 3}, "duplicate");
    checkReverse(5, {1, 9, 3}, "out of range ignored");
    checkReverse(3, {7, 8}, "all out of range");
    for (int iter = 0; iter < 2000; iter++) {
        size_t n = nextRand() % 30;
        std::vector<size_t> positions;
        for (size_t i = 0; i < n + 3; i++) {
            if (nextRand() % 3 == 0) positions.push_back(nextRand() % (n + 3));
        }
        checkReverse(n, positions, "random");
    }

    TEST_MAIN_END();
}
