//
//  IntakeRootErrors.mm
//  foo_jl_intake
//

#include "IntakeRootErrors.h"

#include <unordered_set>

namespace intake {

void RootErrorStore::set(const std::string &id, std::string text, IntakeStatus baseline) {
    if (text.empty()) {
        clear(id);
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    Entry &e = entries_[id];
    e.text = std::move(text);
    e.hasBaseline = baseline != IntakeStatus::Unknown;
    e.baseline = baseline;
}

void RootErrorStore::clear(const std::string &id) {
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.erase(id);
}

void RootErrorStore::clearAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.clear();
}

void RootErrorStore::apply(std::vector<IntakeRecord> &records) {
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
        if (present.count(it->first)) {
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

} // namespace intake
