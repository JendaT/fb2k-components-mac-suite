//
//  QueueFormatting.cpp
//  foo_jl_queue_manager
//
//  Pure string formatting — see QueueFormatting.h.
//  Behavior matches the previous pfc-based implementations exactly.
//

#include "QueueFormatting.h"

namespace queue_format {

namespace {

std::string twoDigits(int value) {
    std::string s = std::to_string(value);
    return (s.size() < 2) ? "0" + s : s;
}

}  // namespace

std::string formatDurationSeconds(double lengthSeconds) {
    if (lengthSeconds <= 0) {
        return "--:--";
    }

    int seconds = static_cast<int>(lengthSeconds);
    int minutes = seconds / 60;
    seconds = seconds % 60;

    if (minutes >= 60) {
        int hours = minutes / 60;
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
