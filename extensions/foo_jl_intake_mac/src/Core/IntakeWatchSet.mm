//
//  IntakeWatchSet.mm
//  foo_jl_intake
//

#include "IntakeWatchSet.h"

#include "IntakePath.h"

#include <algorithm>
#include <climits>
#include <deque>
#include <sys/stat.h>
#include <unistd.h>
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

std::string keyFor(const std::string &path) {
    std::string key;
    if (normalizePath(path, key) != PathStatus::Ok) key.clear();
    return key;
}

constexpr int kMaxSymlinks = 32;  // MAXSYMLINKS
constexpr std::string_view kDataVolume = "/System/Volumes/Data";

// The '/'-separated parts of `path`, empty ones dropped.
void appendParts(std::string_view path, std::deque<std::string> &into, bool front) {
    std::vector<std::string> parts;
    size_t start = 0;
    while (start <= path.size()) {
        size_t end = path.find('/', start);
        if (end == std::string_view::npos) end = path.size();
        if (end > start) parts.emplace_back(path.substr(start, end - start));
        start = end + 1;
    }
    if (front) {
        into.insert(into.begin(), parts.begin(), parts.end());
    } else {
        into.insert(into.end(), parts.begin(), parts.end());
    }
}

std::string joinPath(const std::string &directory, std::string_view name) {
    std::string out = directory;
    if (out.empty() || out.back() != '/') out += '/';
    out.append(name.data(), name.size());
    return out;
}

} // anonymous namespace

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
    // Both sides as IntakePath keys (NFC), as MountAliases::build does: an
    // NFD mount point must still hold the NFC spelling of a path under it.
    std::string pathKey;
    if (normalizePath(path, pathKey) != PathStatus::Ok) return nullptr;
    const MountEntry *best = nullptr;
    size_t bestLength = 0;
    std::string point;
    for (const MountEntry &m : mounts) {
        if (normalizePath(m.mountPoint, point) != PathStatus::Ok) continue;
        size_t length = 0;
        if (isUnderIgnoringCase(pathKey, point)) {
            length = point.size();
        } else if (point.size() > kDataVolume.size() + 1 && isUnderIgnoringCase(point, kDataVolume)) {
            // A mount on the Data volume also holds its firmlinked spelling
            // (/System/Volumes/Data/home is /home).
            const std::string_view firmlinked = std::string_view(point).substr(kDataVolume.size());
            if (isUnderIgnoringCase(pathKey, firmlinked)) length = firmlinked.size();
        }
        if (length == 0) continue;
        // ">=": of two mounts on one point the later one is stacked on top
        // (getmntinfo lists in mount order), as in MountAliases.
        if (!best || length >= bestLength) {
            best = &m;
            bestLength = length;
        }
    }
    return best;
}

bool mayResolvePath(std::string_view path, const std::vector<MountEntry> &mounts) {
    const MountEntry *m = mountHolding(path, mounts);
    return m != nullptr && !isNetworkMount(*m);
}

LinkCheck posixLinkReader(const std::string &path, std::string &target) {
    target.clear();
    struct stat st;
    if (::lstat(path.c_str(), &st) != 0) return LinkCheck::Missing;
    if (!S_ISLNK(st.st_mode)) return LinkCheck::NotLink;
    char buffer[PATH_MAX];
    const ssize_t n = ::readlink(path.c_str(), buffer, sizeof buffer);
    if (n <= 0 || static_cast<size_t>(n) >= sizeof buffer) return LinkCheck::Missing;
    target.assign(buffer, static_cast<size_t>(n));
    return LinkCheck::Link;
}

std::string resolveLocalPath(const std::string &path, const std::vector<MountEntry> &mounts,
                             const LinkReader &readLink, bool *touched) {
    if (touched) *touched = false;
    if (!readLink || path.empty() || path[0] != '/') return path;
    std::deque<std::string> todo;
    appendParts(path, todo, false);
    // Resolved so far: no symlink in it, every component examined locally,
    // so ".." is its physical parent.
    std::string done = "/";
    int links = 0;
    while (!todo.empty()) {
        std::string name = std::move(todo.front());
        todo.pop_front();
        if (name == ".") continue;
        if (name == "..") {
            const std::string parent = parentDirectory(done);
            if (!parent.empty()) done = parent;
            continue;
        }
        const std::string next = joinPath(done, name);
        // Under a network mount, or under none known: not one lstat there.
        if (!mayResolvePath(next, mounts)) {
            todo.push_front(std::move(name));
            break;
        }
        std::string target;
        const LinkCheck check = readLink(next, target);
        if (touched) *touched = true;
        if (check == LinkCheck::NotLink) {
            done = next;
            continue;
        }
        if (check == LinkCheck::Missing || target.empty() || ++links > kMaxSymlinks) {
            todo.push_front(std::move(name));
            if (links > kMaxSymlinks) return path;  // a loop: as written
            break;
        }
        // The link's text replaces it; a relative one is read from `done`.
        if (target[0] == '/') done = "/";
        appendParts(target, todo, true);
    }
    std::string out = done;
    for (const std::string &name : todo) out = joinPath(out, name);
    const std::string clean = lexicalAbsolutePath(out);
    return clean.empty() ? path : clean;
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
                         const LinkReader &readLink) {
    WatchSet set;
    set.entries_.reserve(candidates.size());
    for (const std::string &candidate : candidates) {
        Entry e;
        e.original = lexicalAbsolutePath(candidate);
        if (e.original.empty() || e.original == "/") continue;
        e.fsPath = e.original;
        if (readLink && mayResolvePath(e.original, mounts)) {
            e.fsPath = resolveLocalPath(e.original, mounts, readLink, &e.resolved);
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
