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

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <set>
#include <string>
#include <vector>

static int g_failures = 0;
static int g_checks = 0;

// Naive ground truth: literally remove then insert.
static std::vector<size_t> simulateMove(size_t itemCount,
                                        const std::vector<size_t> &sortedSources,
                                        size_t destIndex) {
    std::set<size_t> sourceSet(sortedSources.begin(), sortedSources.end());
    std::vector<size_t> remaining;
    for (size_t i = 0; i < itemCount; i++) {
        if (!sourceSet.count(i)) remaining.push_back(i);
    }
    size_t insertPos = simplaylist::adjustedReorderDestination(sortedSources, destIndex);
    if (insertPos > remaining.size()) insertPos = remaining.size();
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

// Deterministic PRNG so failures are reproducible.
static uint64_t g_rng = 0xC0FFEE;
static uint64_t nextRand() {
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 7;
    g_rng ^= g_rng << 17;
    return g_rng;
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

    printf("%s: %d checks, %d failures\n",
           g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
