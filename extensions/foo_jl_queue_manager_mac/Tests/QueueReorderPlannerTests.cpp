//
//  QueueReorderPlannerTests.cpp
//  foo_jl_queue_manager
//
//  Unit tests for QueueReorderPlanner (drag-reorder move planning).
//
//  Ground truth is a naive simulation: remove the source item from the
//  list, then insert it at the adjusted destination. The planner's order
//  applied to the identity list must equal it.
//  Pure C++, compiled standalone; run as a gating phase by Scripts/build.sh.
//

#include "../src/Core/QueueReorderPlanner.h"

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

static int g_failures = 0;
static int g_checks = 0;

// Naive ground truth: literally remove then insert.
static std::vector<size_t> simulateMove(size_t itemCount, size_t sourceRow, size_t destRow) {
    if (destRow > itemCount) destRow = itemCount;
    std::vector<size_t> items;
    for (size_t i = 0; i < itemCount; i++) items.push_back(i);
    items.erase(items.begin() + sourceRow);
    size_t insertPos = (sourceRow < destRow) ? destRow - 1 : destRow;
    if (insertPos > items.size()) insertPos = items.size();
    items.insert(items.begin() + insertPos, sourceRow);
    return items;
}

static std::string describe(const std::vector<size_t>& v) {
    std::string s = "[";
    for (size_t i = 0; i < v.size(); i++) {
        if (i) s += ",";
        s += std::to_string(v[i]);
    }
    return s + "]";
}

static void checkMove(size_t itemCount, size_t source, size_t dest, const char* name) {
    g_checks++;
    std::vector<size_t> got = queue_reorder::planSingleMove(itemCount, source, dest);
    std::vector<size_t> want = simulateMove(itemCount, source, dest);
    if (got != want) {
        g_failures++;
        printf("FAIL [%s] N=%zu source=%zu dest=%zu:\n  got  %s\n  want %s\n",
               name, itemCount, source, dest,
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

static void checkEmpty(size_t itemCount, size_t source, size_t dest, const char* name) {
    g_checks++;
    std::vector<size_t> got = queue_reorder::planSingleMove(itemCount, source, dest);
    if (!got.empty()) {
        g_failures++;
        printf("FAIL [%s] N=%zu source=%zu dest=%zu: expected empty, got %s\n",
               name, itemCount, source, dest, describe(got).c_str());
    }
}

static void checkNoop(size_t itemCount, size_t source, size_t dest, bool want, const char* name) {
    g_checks++;
    bool got = queue_reorder::isNoopMove(itemCount, source, dest);
    if (got != want) {
        g_failures++;
        printf("FAIL [%s] N=%zu source=%zu dest=%zu: isNoopMove=%d want %d\n",
               name, itemCount, source, dest, (int)got, (int)want);
    }
}

int main() {
    // No-op detection: dropping at own slot or the slot right after
    checkNoop(5, 2, 2, true, "noop-own-slot");
    checkNoop(5, 2, 3, true, "noop-slot-after");
    checkNoop(5, 2, 4, false, "noop-real-move");
    checkNoop(5, 2, 0, false, "noop-move-to-front");
    checkNoop(5, 4, 5, true, "noop-last-to-end");
    checkNoop(5, 4, 99, true, "noop-last-to-clamped-end");
    checkNoop(1, 0, 0, true, "noop-single-item");
    checkNoop(1, 0, 1, true, "noop-single-item-end");

    // No-ops and invalid input produce an empty plan
    checkEmpty(5, 2, 2, "empty-noop");
    checkEmpty(5, 2, 3, "empty-noop-after");
    checkEmpty(5, 5, 0, "empty-source-out-of-range");
    checkEmpty(0, 0, 0, "empty-queue");

    // Real moves match the naive simulation
    checkMove(5, 0, 5, "first-to-end");
    checkMove(5, 4, 0, "last-to-front");
    checkMove(5, 2, 0, "middle-to-front");
    checkMove(5, 2, 5, "middle-to-end");
    checkMove(5, 0, 2, "forward-one-slot");
    checkMove(5, 3, 1, "backward-two-slots");
    checkMove(2, 0, 2, "swap-pair-forward");
    checkMove(2, 1, 0, "swap-pair-backward");
    checkMove(5, 1, 99, "dest-clamped-to-end");

    // Exhaustive small-N sweep against the simulation
    for (size_t n = 1; n <= 8; n++) {
        for (size_t s = 0; s < n; s++) {
            for (size_t d = 0; d <= n; d++) {
                if (queue_reorder::isNoopMove(n, s, d)) {
                    checkEmpty(n, s, d, "sweep-noop");
                } else {
                    checkMove(n, s, d, "sweep");
                }
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
