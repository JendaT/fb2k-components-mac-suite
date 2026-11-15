//
//  IntakeDebounce.mm
//  foo_jl_intake
//

#include "IntakeDebounce.h"

#include <algorithm>

namespace intake {

namespace {

DebounceWindow::Duration fromSeconds(double seconds) {
    if (seconds < 0) seconds = 0;
    return std::chrono::duration_cast<DebounceWindow::Duration>(std::chrono::duration<double>(seconds));
}

} // anonymous namespace

DebounceWindow::DebounceWindow(Duration quiet, Duration maxWait)
    : quiet_(quiet), maxWait_(std::max(quiet, maxWait)) {}

DebounceWindow::DebounceWindow(double quietSeconds, double maxWaitSeconds)
    : DebounceWindow(fromSeconds(quietSeconds), fromSeconds(maxWaitSeconds)) {}

bool DebounceWindow::add(TimePoint now) {
    if (!pending_) {
        pending_ = true;
        first_ = now;
        last_ = now;
        return true;
    }
    if (now > last_) last_ = now;
    return false;
}

DebounceWindow::TimePoint DebounceWindow::due() const {
    return std::min(last_ + quiet_, first_ + maxWait_);
}

bool DebounceWindow::fire(TimePoint now) {
    if (!pending_ || now < due()) return false;
    pending_ = false;
    return true;
}

} // namespace intake
