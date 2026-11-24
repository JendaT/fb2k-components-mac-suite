//
//  IntakeRunProgress.mm
//  foo_jl_intake
//
//  See IntakeRunProgress.h.
//

#include "IntakeRunProgress.h"

#include <algorithm>

namespace intake {

void RunProgress::start(const std::vector<std::string> &ids, bool resume, const RunStatusLookup &lookup) {
    ids_.clear();
    for (const std::string &id : ids) {
        if (std::find(ids_.begin(), ids_.end(), id) == ids_.end()) ids_.push_back(id);
    }
    last_.assign(ids_.size(), IntakeStatus::Unknown);
    resume_ = resume;
    done_ = 0;
    current_.clear();
    for (size_t i = 0; i < ids_.size(); i++) {
        IntakeStatus status = IntakeStatus::Unknown;
        if (lookup && lookup(ids_[i], status)) last_[i] = status;
        if (last_[i] == IntakeStatus::Placed) done_++;
        if (!resume_ && last_[i] == IntakeStatus::Placing) current_ = ids_[i];
    }
}

bool RunProgress::update(const RunStatusLookup &lookup) {
    uint32_t done = 0;
    std::string becamePlacing;
    std::string currentStatusOk;  // current_ when it is still placing
    for (size_t i = 0; i < ids_.size(); i++) {
        IntakeStatus now = last_[i];
        IntakeStatus seen = IntakeStatus::Unknown;
        if (lookup && lookup(ids_[i], seen)) now = seen;
        if (now == IntakeStatus::Placed) done++;
        if (!resume_ && now == IntakeStatus::Placing) {
            if (last_[i] != IntakeStatus::Placing) becamePlacing = ids_[i];
            if (ids_[i] == current_) currentStatusOk = current_;
        }
        last_[i] = now;
    }
    std::string current = resume_ ? std::string() : (!becamePlacing.empty() ? becamePlacing : currentStatusOk);
    const bool changed = done != done_ || current != current_;
    done_ = done;
    current_ = std::move(current);
    return changed;
}

} // namespace intake
