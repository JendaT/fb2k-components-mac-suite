//
//  IntakeWatchSet.mm
//  foo_jl_intake
//

#include "IntakeWatchSet.h"

#include "IntakePath.h"

#include <algorithm>
#include <climits>
#include <cstdlib>
#include <unordered_set>

namespace intake {

namespace {

char asciiLower(char c) {
    return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
}

// `key` equals `base` or lies under it ('/' boundary), ignoring ASCII case.
bool isUnderIgnoringCase(std::string_view key, std::string_view base) {
    if (base == "/") return !key.empty() && key[0] == '/';
    if (key.size() < base.size() || (key.size() > base.size() && key[base.size()] != '/')) return false;
    for (size_t i = 0; i < base.size(); i++) {
        if (asciiLower(key[i]) != asciiLower(base[i])) return false;
    }
    return true;
}

// Same, byte-exact.
bool isUnderExact(std::string_view key, std::string_view base) {
    if (base == "/") return !key.empty() && key[0] == '/';
    if (key.size() < base.size() || key.compare(0, base.size(), base) != 0) return false;
    return key.size() == base.size() || key[base.size()] == '/';
}

std::string_view trimmedLine(std::string_view s) {
    size_t begin = 0, end = s.size();
    while (begin < end && (s[begin] == ' ' || s[begin] == '\t')) begin++;
    while (end > begin && (s[end - 1] == ' ' || s[end - 1] == '\t')) end--;
    return s.substr(begin, end - begin);
}

std::string keyFor(const std::string &path) {
    std::string key;
    if (normalizePath(path, key) != PathStatus::Ok) key.clear();
    return key;
}

// realpath of `path`, or of its deepest existing ancestor with the rest
// appended as written. `path` is lexically clean and absolute.
std::string resolveWithAncestors(const std::string &path, const PathResolver &resolve) {
    std::string head = path;
    std::string tail;
    while (true) {
        std::string resolved;
        if (resolve(head, resolved) && !resolved.empty() && resolved[0] == '/') {
            if (tail.empty()) return resolved;
            if (resolved.back() != '/') resolved += '/';
            return resolved + tail;
        }
        if (head == "/") return path;
        const std::string parent = parentDirectory(head);
        if (parent.empty()) return path;
        const std::string name = head.substr(parent == "/" ? 1 : parent.size() + 1);
        tail = tail.empty() ? name : name + "/" + tail;
        head = parent;
    }
}

} // anonymous namespace

WatchFolderList parseWatchFolders(std::string_view text) {
    WatchFolderList out;
    std::unordered_set<std::string> seen;
    size_t start = 0;
    while (start <= text.size()) {
        size_t end = text.find_first_of("\r\n", start);
        if (end == std::string_view::npos) end = text.size();
        const std::string_view line = trimmedLine(text.substr(start, end - start));
        if (!line.empty()) {
            if (line[0] == '/') {
                std::string folder(line);
                if (seen.insert(folder).second) out.folders.push_back(std::move(folder));
            } else {
                out.ignored.emplace_back(line);
            }
        }
        start = end + 1;
    }
    return out;
}

std::string lexicalAbsolutePath(std::string_view path) {
    if (path.empty() || path[0] != '/') return std::string();
    std::vector<std::string_view> parts;
    size_t start = 1;
    while (start <= path.size()) {
        size_t end = path.find('/', start);
        if (end == std::string_view::npos) end = path.size();
        const std::string_view part = path.substr(start, end - start);
        if (part.empty() || part == ".") {
            // skip
        } else if (part == "..") {
            if (!parts.empty()) parts.pop_back();
        } else {
            parts.push_back(part);
        }
        start = end + 1;
    }
    if (parts.empty()) return "/";
    std::string out;
    for (std::string_view part : parts) {
        out += '/';
        out.append(part.data(), part.size());
    }
    return out;
}

std::string parentDirectory(std::string_view path) {
    if (path.size() < 2 || path[0] != '/') return std::string();
    const size_t slash = path.rfind('/');
    if (slash == 0) return "/";
    return std::string(path.substr(0, slash));
}

bool isNetworkMount(const MountEntry &mount) {
    if (!mount.local) return true;
    static const char *const kNetworkTypes[] = {
        "smbfs", "nfs", "afpfs", "webdav", "cifs", "ftp", "autofs", "macfuse", "osxfuse", "fusefs", "fuse-t",
    };
    for (const char *type : kNetworkTypes) {
        if (mount.fsType == type) return true;
    }
    return false;
}

const MountEntry *mountHolding(std::string_view path, const std::vector<MountEntry> &mounts) {
    const MountEntry *best = nullptr;
    size_t bestLength = 0;
    for (const MountEntry &m : mounts) {
        const std::string point = lexicalAbsolutePath(m.mountPoint);
        if (point.empty() || !isUnderIgnoringCase(path, point)) continue;
        if (!best || point.size() > bestLength) {
            best = &m;
            bestLength = point.size();
        }
    }
    return best;
}

bool mayResolvePath(std::string_view path, const std::vector<MountEntry> &mounts) {
    const MountEntry *m = mountHolding(path, mounts);
    return m != nullptr && !isNetworkMount(*m);
}

bool realPathResolver(const std::string &path, std::string &resolved) {
    char buffer[PATH_MAX];
    if (::realpath(path.c_str(), buffer) == nullptr) return false;
    resolved = buffer;
    return true;
}

std::vector<std::string> watchCandidates(const std::vector<std::string> &configured,
                                         const std::vector<std::string> &income,
                                         const std::vector<std::string> &rootPaths) {
    std::vector<std::string> out;
    std::unordered_set<std::string> seen;
    auto add = [&](const std::string &clean) {
        if (clean.empty() || clean == "/") return;
        if (seen.insert(clean).second) out.push_back(clean);
    };
    for (const std::string &p : configured) add(lexicalAbsolutePath(p));
    for (const std::string &p : income) add(lexicalAbsolutePath(p));
    for (const std::string &p : rootPaths) add(parentDirectory(lexicalAbsolutePath(p)));
    return out;
}

WatchSet WatchSet::build(const std::vector<std::string> &candidates, const std::vector<MountEntry> &mounts,
                         const PathResolver &resolve) {
    WatchSet set;
    set.entries_.reserve(candidates.size());
    for (const std::string &candidate : candidates) {
        Entry e;
        e.original = lexicalAbsolutePath(candidate);
        if (e.original.empty() || e.original == "/") continue;
        e.fsPath = e.original;
        if (resolve && mayResolvePath(e.original, mounts)) {
            e.fsPath = lexicalAbsolutePath(resolveWithAncestors(e.original, resolve));
            if (e.fsPath.empty()) e.fsPath = e.original;
            e.resolved = true;
        }
        if (e.fsPath == "/") continue;
        e.originalKey = keyFor(e.original);
        e.fsKey = keyFor(e.fsPath);
        if (e.originalKey.empty() || e.fsKey.empty()) continue;
        set.entries_.push_back(std::move(e));
    }

    // Top-level ancestors by key: shortest first, then drop whatever lies
    // under (or equals) a path already kept.
    std::vector<const Entry *> order;
    order.reserve(set.entries_.size());
    for (const Entry &e : set.entries_) order.push_back(&e);
    std::sort(order.begin(), order.end(), [](const Entry *a, const Entry *b) {
        if (a->fsKey.size() != b->fsKey.size()) return a->fsKey.size() < b->fsKey.size();
        return a->fsKey < b->fsKey;
    });
    std::vector<const Entry *> kept;
    for (const Entry *e : order) {
        bool covered = false;
        for (const Entry *k : kept) {
            if (isUnderExact(e->fsKey, k->fsKey)) {
                covered = true;
                break;
            }
        }
        if (!covered) kept.push_back(e);
    }
    for (const Entry *e : kept) set.streamPaths_.push_back(e->fsPath);
    std::sort(set.streamPaths_.begin(), set.streamPaths_.end());
    return set;
}

bool WatchSet::mapEventDirectory(std::string_view directory, const MountAliases &aliases,
                                 std::vector<std::string> &keys) const {
    std::string eventKey;
    if (normalizePath(directory, eventKey) != PathStatus::Ok) return false;
    bool matched = false;
    std::string translated;
    std::string buffer;
    for (const Entry &e : entries_) {
        if (!isUnderIgnoringCase(eventKey, e.fsKey)) continue;
        matched = true;
        // Neither key is "/" (build() skips it), so the rest starts at '/'.
        translated = e.originalKey;
        translated.append(eventKey, e.fsKey.size(), std::string::npos);
        std::string key;
        if (normalizePath(translated, key) != PathStatus::Ok) continue;
        std::string aliased(aliases.rewrite(key, buffer));
        if (std::find(keys.begin(), keys.end(), aliased) == keys.end()) keys.push_back(std::move(aliased));
    }
    return matched;
}

} // namespace intake
