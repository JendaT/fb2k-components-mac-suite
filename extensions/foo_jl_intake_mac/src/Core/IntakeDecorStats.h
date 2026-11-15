//
//  IntakeDecorStats.h
//  foo_jl_intake
//
//  Provider-side decorate counters behind the hidden option
//  foo_jl_intake.decor_stats (PLAN.md B3 "INTAKE_DECOR_STATS";
//  docs/hidden-options.md). They measure the host's cache hit rate without
//  any SimPlaylist change: v2 re-queries a handle only when its store has no
//  entry for it (after a provider invalidation, an index remap or a metadb
//  change), so every decorate item since the provider's last invalidation is
//  one host miss. The >=99% gate: on a 5k-row playlist, scroll twice with no
//  invalidation between the passes; pass 2 may request at most 50 items.
//
//  Counters: successful loads, invalidate-alls fired, decorate batches,
//  items (in total and since the last invalidation) and batch time in
//  microseconds (total, last, maximum). The provider records batches only
//  while the option is on; with it off, decorate() pays one relaxed atomic
//  load and nothing here runs.
//
//  Thread-safety: relaxed atomics; batches may be recorded from several host
//  queues at once. A figures() read is not a consistent snapshot across
//  counters (each value is exact on its own), which is enough for a log line.
//

#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>

namespace intake {

struct DecorStatsFigures {
    uint64_t loads = 0;
    uint64_t invalidations = 0;
    uint64_t batches = 0;
    uint64_t items = 0;
    uint64_t itemsSinceInvalidation = 0;
    uint64_t batchMicrosTotal = 0;
    uint64_t batchMicrosMax = 0;
    uint64_t lastBatchItems = 0;
    uint64_t lastBatchMicros = 0;
};

class DecorStats {
public:
    void noteLoad();
    // An invalidate-all fired: restarts the count of items since then.
    void noteInvalidation();
    void noteBatch(uint64_t items, uint64_t micros);
    DecorStatsFigures figures() const;

    // "decor_stats: batch 64 items 120 us; since invalidation 128 items; ..."
    static std::string formatLine(const DecorStatsFigures &figures);

private:
    std::atomic<uint64_t> loads_{0};
    std::atomic<uint64_t> invalidations_{0};
    std::atomic<uint64_t> batches_{0};
    std::atomic<uint64_t> items_{0};
    std::atomic<uint64_t> itemsSinceInvalidation_{0};
    std::atomic<uint64_t> batchMicrosTotal_{0};
    std::atomic<uint64_t> batchMicrosMax_{0};
    std::atomic<uint64_t> lastBatchItems_{0};
    std::atomic<uint64_t> lastBatchMicros_{0};
};

} // namespace intake
