//
//  IntakeRootErrors.mm
//  foo_jl_intake
//

#include "IntakeRootErrors.h"

#include <unordered_set>

namespace intake {

void RootErrorStore::set(const std::string &id, std::string text, IntakeStatus baseline, Clock::time_point at) {
    put(id, std::move(text), baseline, at, false);
}

void RootErrorStore::setTimeout(const std::string &id, std::string text, IntakeStatus baseline,
                                Clock::time_point at) {
    put(id, std::move(text), baseline, at, true);
}

void RootErrorStore::put(const std::string &id, std::string text, IntakeStatus baseline, Clock::time_point at,
                         bool timeout) {
    if (text.empty()) {
        clear(id);
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    Entry &e = entries_[id];
    e.text = std::move(text);
    e.hasBaseline = baseline != IntakeStatus::Unknown;
    e.baseline = baseline;
    e.setAt = at;
    e.timeout = timeout;
}

void RootErrorStore::clear(const std::string &id) {
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.erase(id);
}

void RootErrorStore::clearAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.clear();
}

size_t RootErrorStore::clearTimeouts() {
    std::lock_guard<std::mutex> lock(mutex_);
    size_t cleared = 0;
    for (auto it = entries_.begin(); it != entries_.end();) {
        if (it->second.timeout) {
            it = entries_.erase(it);
            cleared++;
        } else {
            ++it;
        }
    }
    return cleared;
}

void RootErrorStore::apply(std::vector<IntakeRecord> &records, Clock::time_point statusStarted) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (entries_.empty()) {
        for (IntakeRecord &r : records) r.lastError.clear();
        return;
    }
    std::unordered_set<std::string> present;
    present.reserve(records.size());
    for (IntakeRecord &r : records) {
        present.insert(r.id);
        auto it = entries_.find(r.id);
        if (it == entries_.end()) {
            r.lastError.clear();
            continue;
        }
        Entry &e = it->second;
        if (e.setAt >= statusStarted) {
            // The call may have read the status from before the error:
            // shown, but this load decides nothing about it.
            r.lastError = e.text;
            continue;
        }
        if (!e.hasBaseline) {
            e.hasBaseline = true;
            e.baseline = r.status;
        } else if (e.baseline != r.status) {
            entries_.erase(it);
            r.lastError.clear();
            continue;
        }
        r.lastError = e.text;
    }
    for (auto it = entries_.begin(); it != entries_.end();) {
        if (present.count(it->first) || it->second.setAt >= statusStarted) {
            ++it;
        } else {
            it = entries_.erase(it);
        }
    }
}

size_t RootErrorStore::size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return entries_.size();
}

std::string RootErrorStore::errorFor(const std::string &id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(id);
    return it == entries_.end() ? std::string() : it->second.text;
}

bool RootErrorStore::isTimeout(const std::string &id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(id);
    return it != entries_.end() && it->second.timeout;
}

} // namespace intake
