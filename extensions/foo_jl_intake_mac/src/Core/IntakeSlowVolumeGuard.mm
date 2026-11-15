//
//  IntakeSlowVolumeGuard.mm
//  foo_jl_intake
//

#include "IntakeSlowVolumeGuard.h"

#include <algorithm>
#include <strings.h>

namespace intake {

namespace {

constexpr std::string_view kMacVolumeScheme = "mac-volume://";

} // anonymous namespace

std::string_view macVolumeUuid(std::string_view path) {
    if (path.size() <= kMacVolumeScheme.size()) return std::string_view();
    if (strncasecmp(path.data(), kMacVolumeScheme.data(), kMacVolumeScheme.size()) != 0) return std::string_view();
    const std::string_view rest = path.substr(kMacVolumeScheme.size());
    const size_t slash = rest.find('/');
    return slash == std::string_view::npos ? rest : rest.substr(0, slash);
}

bool NativePathMenuBudget::allows(std::string_view uuid) const {
    if (!spent_) return true;
    if (std::find(fast_.begin(), fast_.end(), uuid) != fast_.end()) return true;
    skipped_++;
    return false;
}

void NativePathMenuBudget::note(std::string_view uuid, uint64_t micros) {
    if (isSlowNativePathCall(micros)) {
        spent_ = true;
        return;
    }
    if (fast_.empty() || fast_.back() != uuid) {
        if (std::find(fast_.begin(), fast_.end(), uuid) == fast_.end()) fast_.emplace_back(uuid);
    }
}

bool SlowVolumeGuard::isSlow(std::string_view uuid) const {
    if (uuid.empty() || !any_.load(std::memory_order_acquire)) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    return std::find(slow_.begin(), slow_.end(), uuid) != slow_.end();
}

bool SlowVolumeGuard::noteCall(std::string_view uuid, uint64_t micros, uint64_t generation) {
    if (uuid.empty()) return false;
    const bool slowCall = isSlowNativePathCall(micros);
    // The common case: a fast call and no streak anywhere.
    if (!slowCall && !anyStreak_.load(std::memory_order_acquire)) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    auto streak = std::find_if(streaks_.begin(), streaks_.end(), [uuid](const Streak &s) { return s.uuid == uuid; });
    if (!slowCall) {
        // A fast call ends the UUID's streak.
        if (streak != streaks_.end()) streaks_.erase(streak);
        anyStreak_.store(!streaks_.empty(), std::memory_order_release);
        return false;
    }
    // Under the lock, so a reset() cannot slip between this check and the
    // insert.
    if (generation != generation_.load(std::memory_order_acquire)) return false;
    if (std::find(slow_.begin(), slow_.end(), uuid) != slow_.end()) return false;
    if (streak == streaks_.end()) {
        streaks_.push_back({std::string(uuid), 0});
        streak = streaks_.end() - 1;
    }
    if (++streak->slowCalls < kSlowCallsToMark) {
        anyStreak_.store(true, std::memory_order_release);
        return false;
    }
    streaks_.erase(streak);
    anyStreak_.store(!streaks_.empty(), std::memory_order_release);
    slow_.emplace_back(uuid);
    any_.store(true, std::memory_order_release);
    return true;
}

void SlowVolumeGuard::reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    generation_.fetch_add(1, std::memory_order_acq_rel);
    slow_.clear();
    streaks_.clear();
    any_.store(false, std::memory_order_release);
    anyStreak_.store(false, std::memory_order_release);
}

size_t SlowVolumeGuard::slowCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return slow_.size();
}

} // namespace intake
