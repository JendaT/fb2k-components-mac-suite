//
//  QueueReorderPlannerTests.cpp
//  foo_jl_queue_manager
//
//  Unit tests for QueueReorderPlanner (drag-reorder move planning).
//
//  Ground truth is a naive simulation: remove the source items from the
//  list, then insert them (in original order) at the adjusted destination.
//  The planner's order applied to the identity list must equal it, except
//  the planner signals identity results (no-op moves) with an empty vector.
//  Pure C++, compiled standalone; run as a gating phase by Scripts/build.sh.
//

#include "../src/Core/QueueReorderPlanner.h"

#include <algorithm>
#include <cstdio>
#include <set>
#include <string>
#include <vector>

static int g_failures = 0;
static int g_checks = 0;

// Naive ground truth: literally remove then insert.
static std::vector<size_t> simulateMove(size_t itemCount,
                                        const std::vector<size_t>& sortedSources,
                                        size_t destRow) {
    if (destRow > itemCount) destRow = itemCount;
    std::set<size_t> sourceSet(sortedSources.begin(), sortedSources.end());
    std::vector<size_t> remaining;
    for (size_t i = 0; i < itemCount; i++) {
        if (!sourceSet.count(i)) remaining.push_back(i);
    }
    size_t insertPos = destRow;
    for (size_t s : sortedSources) {
        if (s < destRow) insertPos--;
    }
    if (insertPos > remaining.size()) insertPos = remaining.size();
    std::vector<size_t> result(remaining.begin(), remaining.begin() + insertPos);
    result.insert(result.end(), sortedSources.begin(), sortedSources.end());
    result.insert(result.end(), remaining.begin() + insertPos, remaining.end());
    return result;
}

static bool isIdentity(const std::vector<size_t>& v) {
    for (size_t i = 0; i < v.size(); i++) {
        if (v[i] != i) return false;
    }
    return true;
}

static std::string describe(const std::vector<size_t>& v) {
    std::string s = "[";
    for (size_t i = 0; i < v.size(); i++) {
        if (i) s += ",";
        s += std::to_string(v[i]);
    }
    return s + "]";
}

// Real moves must match the simulation; identity moves must return empty.
static void checkMove(size_t itemCount, const std::vector<size_t>& sources,
                      size_t dest, const char* name) {
    g_checks++;
    std::vector<size_t> got = queue_reorder::planMove(itemCount, sources, dest);
    std::vector<size_t> want = simulateMove(itemCount, sources, dest);
    if (isIdentity(want)) {
        if (!got.empty()) {
            g_failures++;
            printf("FAIL [%s] N=%zu sources=%s dest=%zu: expected empty (no-op), got %s\n",
                   name, itemCount, describe(sources).c_str(), dest, describe(got).c_str());
        }
        return;
    }
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

static void checkEmpty(size_t itemCount, const std::vector<size_t>& sources,
                       size_t dest, const char* name) {
    g_checks++;
    std::vector<size_t> got = queue_reorder::planMove(itemCount, sources, dest);
    if (!got.empty()) {
        g_failures++;
        printf("FAIL [%s] N=%zu sources=%s dest=%zu: expected empty, got %s\n",
               name, itemCount, describe(sources).c_str(), dest, describe(got).c_str());
    }
}

int main() {
    // Invalid input produces an empty plan
    checkEmpty(5, {}, 2, "empty-sources");
    checkEmpty(5, {5}, 0, "source-out-of-range");
    checkEmpty(5, {2, 2}, 0, "duplicate-sources");
    checkEmpty(5, {3, 1}, 0, "unsorted-sources");
    checkEmpty(0, {0}, 0, "empty-queue");

    // Single-item no-ops: dropping at own slot or the slot right after
    checkEmpty(5, {2}, 2, "noop-own-slot");
    checkEmpty(5, {2}, 3, "noop-slot-after");
    checkEmpty(5, {4}, 5, "noop-last-to-end");
    checkEmpty(5, {4}, 99, "noop-last-to-clamped-end");
    checkEmpty(1, {0}, 0, "noop-single-item");
    checkEmpty(1, {0}, 1, "noop-single-item-end");

    // Multi-item no-ops: contiguous block dropped back onto itself
    checkEmpty(5, {1, 2}, 1, "noop-block-own-slot");
    checkEmpty(5, {1, 2}, 2, "noop-block-inside");
    checkEmpty(5, {1, 2}, 3, "noop-block-after");
    checkEmpty(3, {0, 1, 2}, 1, "noop-move-everything");

    // Single-item real moves
    checkMove(5, {0}, 5, "first-to-end");
    checkMove(5, {4}, 0, "last-to-front");
    checkMove(5, {2}, 0, "middle-to-front");
    checkMove(5, {2}, 5, "middle-to-end");
    checkMove(5, {0}, 2, "forward-one-slot");
    checkMove(5, {3}, 1, "backward-two-slots");
    checkMove(2, {0}, 2, "swap-pair-forward");
    checkMove(2, {1}, 0, "swap-pair-backward");
    checkMove(5, {1}, 99, "dest-clamped-to-end");

    // Multi-item real moves
    checkMove(5, {0, 1}, 5, "block-to-end");
    checkMove(5, {3, 4}, 0, "block-to-front");
    checkMove(6, {1, 4}, 6, "gapped-pair-to-end");
    checkMove(6, {0, 2, 4}, 3, "interleaved-to-middle");
    checkMove(6, {0, 5}, 3, "ends-to-middle");
    checkMove(10, {2, 3, 7}, 5, "dest-inside-source-gap");

    // Exhaustive sweep: every non-empty source subset of every small queue,
    // every destination, against the naive simulation
    for (size_t n = 1; n <= 7; n++) {
        for (size_t mask = 1; mask < ((size_t)1 << n); mask++) {
            std::vector<size_t> sources;
            for (size_t i = 0; i < n; i++) {
                if (mask & ((size_t)1 << i)) sources.push_back(i);
            }
            for (size_t d = 0; d <= n; d++) {
                checkMove(n, sources, d, "sweep");
            }
        }
    }

    if (g_failures) {
        printf("QueueReorderPlannerTests: %d/%d checks FAILED\n", g_failures, g_checks);
        return 1;
    }
    printf("QueueReorderPlannerTests: all %d checks passed\n", g_checks);
    return 0;
}
