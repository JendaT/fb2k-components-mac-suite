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

bool SlowVolumeGuard::isSlow(std::string_view uuid) const {
    if (uuid.empty() || !any_.load(std::memory_order_acquire)) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    return std::find(slow_.begin(), slow_.end(), uuid) != slow_.end();
}

bool SlowVolumeGuard::noteCall(std::string_view uuid, uint64_t micros, uint64_t generation) {
    if (uuid.empty() || !isSlowNativePathCall(micros)) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    // Under the lock, so a reset() cannot slip between this check and the
    // insert.
    if (generation != generation_.load(std::memory_order_acquire)) return false;
    if (std::find(slow_.begin(), slow_.end(), uuid) != slow_.end()) return false;
    slow_.emplace_back(uuid);
    any_.store(true, std::memory_order_release);
    return true;
}

void SlowVolumeGuard::reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    generation_.fetch_add(1, std::memory_order_acq_rel);
    slow_.clear();
    any_.store(false, std::memory_order_release);
}

size_t SlowVolumeGuard::slowCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return slow_.size();
}

} // namespace intake
