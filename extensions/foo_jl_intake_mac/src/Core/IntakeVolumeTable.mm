//
//  IntakeVolumeTable.mm
//  foo_jl_intake
//

#include "IntakeVolumeTable.h"

#include <strings.h>

namespace intake {

namespace {

constexpr std::string_view kMacVolumeScheme = "mac-volume://";

char asciiLower(char c) {
    return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
}

bool equalsIgnoringCase(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); i++) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

const VolumeEntry *findEntry(const std::vector<VolumeEntry> &entries, std::string_view uuid) {
    for (const VolumeEntry &e : entries) {
        if (equalsIgnoringCase(e.uuid, uuid)) return &e;
    }
    return nullptr;
}

} // anonymous namespace

bool splitMacVolumePath(std::string_view path, std::string_view &uuid, std::string_view &rest) {
    if (path.size() <= kMacVolumeScheme.size()) return false;
    if (strncasecmp(path.data(), kMacVolumeScheme.data(), kMacVolumeScheme.size()) != 0) return false;
    const std::string_view after = path.substr(kMacVolumeScheme.size());
    const size_t slash = after.find('/');
    uuid = slash == std::string_view::npos ? after : after.substr(0, slash);
    rest = slash == std::string_view::npos ? std::string_view() : after.substr(slash + 1);
    return !uuid.empty();
}

std::string_view volumeIdOfRoot(std::string_view canonical) {
    std::string_view uuid;
    std::string_view rest;
    if (!splitMacVolumePath(canonical, uuid, rest) || !rest.empty()) return std::string_view();
    return uuid;
}

std::string volumeRootFromNative(std::string_view native) {
    if (native.empty() || native.front() != '/') return std::string();
    while (native.size() > 1 && native.back() == '/') native.remove_suffix(1);
    return std::string(native);
}

std::string learnedVolumeRoot(std::string_view itemPath, std::string_view native) {
    std::string_view uuid;
    std::string_view rest;
    if (!splitMacVolumePath(itemPath, uuid, rest) || rest.empty()) return std::string();
    // native == root + "/" + rest, with a non-empty absolute root.
    if (native.size() < rest.size() + 2) return std::string();
    if (native.substr(native.size() - rest.size()) != rest) return std::string();
    const std::string_view head = native.substr(0, native.size() - rest.size());
    if (head.back() != '/') return std::string();
    return volumeRootFromNative(head);
}

std::shared_ptr<const VolumeTable> VolumeTable::make(std::vector<VolumeEntry> entries) {
    auto table = std::make_shared<VolumeTable>(Token{});
    table->entries_.reserve(entries.size());
    for (VolumeEntry &e : entries) {
        if (e.uuid.empty() || e.root.empty()) continue;
        if (findEntry(table->entries_, e.uuid) != nullptr) continue;
        table->entries_.push_back(std::move(e));
    }
    return table;
}

std::shared_ptr<const VolumeTable> VolumeTable::empty() {
    static const std::shared_ptr<const VolumeTable> none = std::make_shared<VolumeTable>(Token{});
    return none;
}

const std::string *VolumeTable::rootFor(std::string_view uuid) const {
    const VolumeEntry *e = findEntry(entries_, uuid);
    return e == nullptr ? nullptr : &e->root;
}

bool VolumeTable::nativePath(std::string_view uuid, std::string_view rest, std::string &out) const {
    const std::string *root = rootFor(uuid);
    if (root == nullptr) return false;
    out.assign(*root);
    if (!rest.empty()) {
        if (out.back() != '/') out.push_back('/');
        out.append(rest.data(), rest.size());
    }
    return true;
}

bool VolumeTable::nativePath(std::string_view itemPath, std::string &out) const {
    std::string_view uuid;
    std::string_view rest;
    if (!splitMacVolumePath(itemPath, uuid, rest)) return false;
    return nativePath(uuid, rest, out);
}

std::shared_ptr<const VolumeTable> VolumeTable::withVolume(std::string uuid, std::string root) const {
    std::vector<VolumeEntry> entries;
    entries.reserve(entries_.size() + 1);
    entries.push_back({std::move(uuid), std::move(root)});
    for (const VolumeEntry &e : entries_) entries.push_back(e);  // make() keeps the first of an id
    return make(std::move(entries));
}

bool VolumeTable::sameAs(const VolumeTable &other) const {
    if (entries_.size() != other.entries_.size()) return false;
    for (const VolumeEntry &e : entries_) {
        const std::string *root = other.rootFor(e.uuid);
        if (root == nullptr || *root != e.root) return false;
    }
    return true;
}

std::string VolumeTable::describe() const {
    if (entries_.empty()) return "none";
    std::string out;
    for (const VolumeEntry &e : entries_) {
        if (!out.empty()) out += "; ";
        out += e.uuid + " -> " + e.root;
    }
    return out;
}

std::shared_ptr<const VolumeTable> mergeSeededVolumes(std::vector<VolumeEntry> seeded, const VolumeTable &previous,
                                                      const std::vector<std::string> &mountPoints) {
    std::vector<std::string> mounted;
    mounted.reserve(mountPoints.size());
    for (const std::string &m : mountPoints) {
        std::string root = volumeRootFromNative(m);
        if (!root.empty()) mounted.push_back(std::move(root));
    }
    for (const VolumeEntry &e : previous.entries()) {
        if (findEntry(seeded, e.uuid) != nullptr) continue;
        for (const std::string &m : mounted) {
            if (equalsIgnoringCase(m, e.root)) {
                seeded.push_back(e);
                break;
            }
        }
    }
    return VolumeTable::make(std::move(seeded));
}

std::vector<VolumeChange> volumeChanges(const VolumeTable &before, const VolumeTable &after) {
    std::vector<VolumeChange> changes;
    for (const VolumeEntry &e : before.entries()) {
        const std::string *now = after.rootFor(e.uuid);
        if (now == nullptr) {
            changes.push_back({e.uuid, e.root, std::string()});
        } else if (*now != e.root) {
            changes.push_back({e.uuid, e.root, *now});
        }
    }
    for (const VolumeEntry &e : after.entries()) {
        if (before.rootFor(e.uuid) == nullptr) changes.push_back({e.uuid, std::string(), e.root});
    }
    return changes;
}

} // namespace intake
