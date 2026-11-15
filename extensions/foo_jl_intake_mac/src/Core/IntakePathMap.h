//
//  IntakePathMap.h
//  foo_jl_intake
//
//  A hash map keyed by normalized paths (IntakePath match keys), with the
//  nearest-ancestor lookup that IntakeRootIndex and IntakeSnapshot share.
//
//  Keys must already be normalized (IntakePath: absolute, no "//", "." or
//  "..", no trailing '/', NFC), and so must every query. find() is an exact
//  match. findNearest() tries the path itself, then each parent up to "/",
//  and returns the first hit: the deepest entry containing the path, so a
//  nested root wins over its parent. Its cost grows with the query's depth,
//  not with the number of entries, and a length bitmap skips the hash for
//  ancestor lengths no key has.
//
//  Lookups take a std::string_view and never build a std::string (C++20
//  heterogeneous lookup), so the decorate path allocates nothing here.
//
//  Thread-safety: insert() and clear() must not run concurrently with
//  anything else on the same map. The const members do not mutate, so any
//  number of them may run concurrently while nothing writes.
//

#pragma once

#include <cstddef>
#include <functional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace intake {

struct PathKeyHash {
    using is_transparent = void;
    size_t operator()(std::string_view s) const noexcept {
        return std::hash<std::string_view>{}(s);
    }
};

template <class Value>
class PathMap {
public:
    void clear() {
        map_.clear();
        hasLength_.clear();
    }

    void reserve(size_t count) { map_.reserve(count); }
    bool empty() const { return map_.empty(); }
    size_t size() const { return map_.size(); }

    // Adds `value` under `key`; an empty key is ignored. When the key is
    // already present, `replace(existing, value)` decides whether `value`
    // takes its place (e.g. the lowest identifier wins), so the result does
    // not depend on insertion order.
    template <class Replace>
    void insert(std::string_view key, Value value, Replace replace) {
        if (key.empty()) return;
        auto it = map_.find(key);
        if (it == map_.end()) {
            map_.emplace(std::string(key), std::move(value));
        } else if (replace(it->second, value)) {
            it->second = std::move(value);
        }
        if (key.size() >= hasLength_.size()) hasLength_.resize(key.size() + 1, false);
        hasLength_[key.size()] = true;
    }

    // Exact match, or nullptr. The pointer stays valid until the next write.
    const Value *find(std::string_view key) const {
        if (key.size() >= hasLength_.size() || !hasLength_[key.size()]) return nullptr;
        auto it = map_.find(key);
        return it == map_.end() ? nullptr : &it->second;
    }

    // The entry for `path` itself or for its nearest ancestor, or nullptr.
    const Value *findNearest(std::string_view path) const {
        if (map_.empty() || path.empty()) return nullptr;
        std::string_view candidate = path;
        while (true) {
            if (const Value *hit = find(candidate)) return hit;
            if (candidate.size() <= 1) return nullptr;  // "/" was the last ancestor
            const size_t slash = candidate.rfind('/');
            if (slash == std::string_view::npos) return nullptr;
            candidate = candidate.substr(0, slash == 0 ? 1 : slash);
        }
    }

private:
    std::unordered_map<std::string, Value, PathKeyHash, std::equal_to<>> map_;
    // hasLength_[n]: some key is exactly n bytes long.
    std::vector<bool> hasLength_;
};

} // namespace intake
