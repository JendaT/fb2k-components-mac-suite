//
//  IntakeCallbackList.h
//  foo_jl_intake
//
//  The host callbacks a provider service keeps (the status provider's
//  jl_status_callback, B14; shared/jl_status_api.h "Callback lifetime"):
//  several at once (one per host, or per host panel), each pointer once.
//  add() of null or of one already there, and remove() of one that is not
//  there (never registered, or removed already), do nothing.
//
//  forEach() is one round of calls: it copies the list under the lock and
//  calls each callback outside it, so a callback that re-enters the
//  provider (registers, unregisters, reads its line) cannot deadlock
//  against the lock. Just before each call it checks, under the lock, that
//  the callback is still in the list: one removed meanwhile, by an earlier
//  callback of the same round or by another thread, is not called again.
//  What is left is a call that already began when remove() ran, which the
//  API allows (the host keeps its callback valid after unregistering). One
//  added during a round is first called in the next round. With an empty
//  list a round costs the lock and nothing else (no allocation).
//
//  Pointers only: the list never owns, frees or dereferences them; only
//  forEach's `call` does.
//
//  Thread-safety: every member may be called from any thread.
//

#pragma once

#include <algorithm>
#include <cstddef>
#include <mutex>
#include <vector>

namespace intake {

template <typename T>
class CallbackList {
public:
    // True when `cb` was added (not null, not there yet).
    bool add(T *cb) {
        if (cb == nullptr) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        if (std::find(list_.begin(), list_.end(), cb) != list_.end()) return false;
        list_.push_back(cb);
        return true;
    }

    // True when `cb` was there.
    bool remove(T *cb) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = std::find(list_.begin(), list_.end(), cb);
        if (it == list_.end()) return false;
        list_.erase(it);
        return true;
    }

    bool contains(T *cb) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return std::find(list_.begin(), list_.end(), cb) != list_.end();
    }

    size_t size() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return list_.size();
    }

    bool empty() const { return size() == 0; }

    // One round: `call(cb)` for each callback in the list when the round
    // began that is still in it when its turn comes, outside the lock.
    // Returns how many were called.
    template <typename F>
    size_t forEach(F &&call) {
        std::vector<T *> round;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (list_.empty()) return 0;
            round = list_;
        }
        size_t called = 0;
        for (T *cb : round) {
            if (!contains(cb)) continue;
            call(cb);
            called++;
        }
        return called;
    }

private:
    mutable std::mutex mutex_;
    std::vector<T *> list_;
};

} // namespace intake
