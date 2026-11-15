//
//  IntakeDecorStats.mm
//  foo_jl_intake
//

#include "IntakeDecorStats.h"

namespace intake {

namespace {
constexpr std::memory_order kRelaxed = std::memory_order_relaxed;
}

void DecorStats::noteLoad() {
    loads_.fetch_add(1, kRelaxed);
}

void DecorStats::noteInvalidation() {
    invalidations_.fetch_add(1, kRelaxed);
    itemsSinceInvalidation_.store(0, kRelaxed);
}

void DecorStats::noteBatch(uint64_t items, uint64_t micros) {
    batches_.fetch_add(1, kRelaxed);
    items_.fetch_add(items, kRelaxed);
    itemsSinceInvalidation_.fetch_add(items, kRelaxed);
    batchMicrosTotal_.fetch_add(micros, kRelaxed);
    lastBatchItems_.store(items, kRelaxed);
    lastBatchMicros_.store(micros, kRelaxed);
    uint64_t max = batchMicrosMax_.load(kRelaxed);
    while (micros > max && !batchMicrosMax_.compare_exchange_weak(max, micros, kRelaxed)) {
    }
}

DecorStatsFigures DecorStats::figures() const {
    DecorStatsFigures f;
    f.loads = loads_.load(kRelaxed);
    f.invalidations = invalidations_.load(kRelaxed);
    f.batches = batches_.load(kRelaxed);
    f.items = items_.load(kRelaxed);
    f.itemsSinceInvalidation = itemsSinceInvalidation_.load(kRelaxed);
    f.batchMicrosTotal = batchMicrosTotal_.load(kRelaxed);
    f.batchMicrosMax = batchMicrosMax_.load(kRelaxed);
    f.lastBatchItems = lastBatchItems_.load(kRelaxed);
    f.lastBatchMicros = lastBatchMicros_.load(kRelaxed);
    return f;
}

std::string DecorStats::formatLine(const DecorStatsFigures &f) {
    const uint64_t average = f.batches == 0 ? 0 : f.batchMicrosTotal / f.batches;
    return "decor_stats: batch " + std::to_string(f.lastBatchItems) + " items " + std::to_string(f.lastBatchMicros) +
           " us; since invalidation " + std::to_string(f.itemsSinceInvalidation) + " items; totals " +
           std::to_string(f.batches) + " batches, " + std::to_string(f.items) + " items, avg " +
           std::to_string(average) + " us, max " + std::to_string(f.batchMicrosMax) + " us; loads " +
           std::to_string(f.loads) + ", invalidations " + std::to_string(f.invalidations);
}

} // namespace intake
