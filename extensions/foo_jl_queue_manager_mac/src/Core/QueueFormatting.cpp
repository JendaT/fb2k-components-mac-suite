//
//  QueueFormatting.cpp
//  foo_jl_queue_manager
//
//  Pure string formatting — see QueueFormatting.h.
//  Behavior matches the previous pfc-based implementations exactly.
//

#include "QueueFormatting.h"

#include <cmath>
#include <cstdint>

namespace queue_format {

namespace {

std::string twoDigits(long long value) {
    std::string s = std::to_string(value);
    return (s.size() < 2) ? "0" + s : s;
}

}  // namespace

std::string formatDurationSeconds(double lengthSeconds) {
    // Track lengths come from untrusted media metadata: reject NaN/inf and
    // values that would overflow the integer cast (UB) before converting.
    if (!std::isfinite(lengthSeconds) || lengthSeconds <= 0 ||
        lengthSeconds >= static_cast<double>(INT64_MAX)) {
        return "--:--";
    }

    long long seconds = static_cast<long long>(lengthSeconds);
    long long minutes = seconds / 60;
    seconds = seconds % 60;

    if (minutes >= 60) {
        long long hours = minutes / 60;
        minutes = minutes % 60;
        return std::to_string(hours) + ":" + twoDigits(minutes) + ":" + twoDigits(seconds);
    }
    return std::to_string(minutes) + ":" + twoDigits(seconds);
}

std::string statusTextForCount(size_t count) {
    if (count == 0) return "";
    if (count == 1) return "1 item in queue";
    return std::to_string(count) + " items in queue";
}

}  // namespace queue_format
