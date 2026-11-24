//
//  IntakeMountAliases.mm
//  foo_jl_intake
//

#include "IntakeMountAliases.h"

#include "IntakePath.h"

#include <algorithm>
#include <map>

namespace intake {

namespace {

int hexValue(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// %XX decoded, except escapes of '/' and NUL, which would change the
// path's structure; a malformed escape stays as written.
std::string percentDecode(std::string_view text) {
    std::string out;
    out.reserve(text.size());
    for (size_t i = 0; i < text.size(); i++) {
        if (text[i] == '%' && i + 2 < text.size()) {
            const int hi = hexValue(text[i + 1]);
            const int lo = hexValue(text[i + 2]);
            if (hi >= 0 && lo >= 0) {
                const char decoded = static_cast<char>(hi * 16 + lo);
                if (decoded != '/' && decoded != '\0') {
                    out += decoded;
                    i += 2;
                    continue;
                }
            }
        }
        out += text[i];
    }
    return out;
}

// Every '/'-separated part is non-empty and neither "." nor "..", so
// normalisation cannot change the key's structure.
bool hasSafeParts(std::string_view path) {
    size_t start = 0;
    while (start <= path.size()) {
        size_t end = path.find('/', start);
        if (end == std::string_view::npos) end = path.size();
        const std::string_view part = path.substr(start, end - start);
        if (part.empty() || part == "." || part == "..") return false;
        start = end + 1;
    }
    return true;
}

char asciiLower(char c) {
    return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
}

// `key` is `mount` or lies under it (both normalized). The mount point is
// compared ignoring ASCII case (see the header); bytes past it are not
// compared here, and ASCII folding keeps lengths, so the caller's
// key.substr(mount.size()) is still the rest of `key`.
bool isUnder(std::string_view key, std::string_view mount) {
    if (mount == "/") return !key.empty() && key[0] == '/';
    if (key.size() < mount.size() || (key.size() > mount.size() && key[mount.size()] != '/')) return false;
    for (size_t i = 0; i < mount.size(); i++) {
        if (asciiLower(key[i]) != asciiLower(mount[i])) return false;
    }
    return true;
}

} // anonymous namespace

std::string smbShareKey(std::string_view source) {
    if (source.size() < 3 || source.compare(0, 2, "//") != 0) return std::string();
    const size_t slash = source.find('/', 2);
    if (slash == std::string_view::npos || slash == 2) return std::string();  // no share, or no host
    std::string_view rest = source.substr(slash + 1);
    while (!rest.empty() && rest.back() == '/') rest.remove_suffix(1);
    if (rest.empty()) return std::string();

    std::string key = percentDecode(rest);
    if (!hasSafeParts(key)) return std::string();
    const size_t shareEnd = std::min(key.find('/'), key.size());
    for (size_t i = 0; i < shareEnd; i++) key[i] = asciiLower(key[i]);
    return key;
}

std::shared_ptr<const MountAliases> MountAliases::build(const std::vector<MountEntry> &mounts) {
    auto table = std::make_shared<MountAliases>(Token{});

    // By normalized mount point. A later row for the same mount point is a
    // mount stacked on top of the earlier one (getmntinfo lists in mount
    // order), so it replaces it.
    std::map<std::string, std::string> byMount;
    std::string mountKey;
    std::string aliasKey;
    for (const MountEntry &m : mounts) {
        if (normalizePath(m.mountPoint, mountKey) != PathStatus::Ok) continue;
        aliasKey.clear();
        if (m.fsType == "smbfs") {
            const std::string share = smbShareKey(m.source);
            if (!share.empty() &&
                normalizePath(std::string(kSmbAliasPrefix) + share, aliasKey) != PathStatus::Ok) {
                aliasKey.clear();
            }
        }
        byMount[mountKey] = aliasKey;
    }

    for (const auto &[mount, alias] : byMount) {
        bool keep = !alias.empty();
        if (!keep) {
            // A pass-through mount matters only inside an smbfs mount.
            for (const auto &[outer, outerAlias] : byMount) {
                if (!outerAlias.empty() && outer.size() < mount.size() && isUnder(mount, outer)) {
                    keep = true;
                    break;
                }
            }
        }
        if (!keep) continue;
        table->entries_.push_back({mount, alias});
        if (!alias.empty()) table->aliasCount_++;
    }
    // Longest first; the map already ordered equal lengths, so the order is
    // a function of the entries alone (sameAs compares in order).
    std::stable_sort(table->entries_.begin(), table->entries_.end(),
                     [](const Entry &a, const Entry &b) { return a.mountKey.size() > b.mountKey.size(); });
    return table;
}

std::shared_ptr<const MountAliases> MountAliases::none() {
    static const std::shared_ptr<const MountAliases> empty = std::make_shared<MountAliases>(Token{});
    return empty;
}

std::string_view MountAliases::rewrite(std::string_view key, std::string &buffer) const {
    for (const Entry &e : entries_) {
        if (!isUnder(key, e.mountKey)) continue;
        if (e.aliasKey.empty()) return key;  // a nested mount that is not smbfs
        std::string_view rest = e.mountKey == "/" ? key : key.substr(e.mountKey.size());
        if (rest == "/") rest = std::string_view();
        buffer.assign(e.aliasKey);
        buffer.append(rest);
        return buffer;
    }
    return key;
}

std::string MountAliases::rewritten(std::string_view key) const {
    std::string buffer;
    return std::string(rewrite(key, buffer));
}

bool MountAliases::hasMountBelow(std::string_view key) const {
    // A mount point longer than `key` that a key under `key` lies under
    // agrees with `key` up to its length (ASCII case aside) and has a '/'
    // right after it: exactly isUnder(mount, key).
    for (const Entry &e : entries_) {
        if (e.mountKey.size() > key.size() && isUnder(e.mountKey, key)) return true;
    }
    return false;
}

bool MountAliases::sameAs(const MountAliases &other) const {
    if (entries_.size() != other.entries_.size()) return false;
    for (size_t i = 0; i < entries_.size(); i++) {
        if (entries_[i].mountKey != other.entries_[i].mountKey ||
            entries_[i].aliasKey != other.entries_[i].aliasKey) {
            return false;
        }
    }
    return true;
}

std::vector<std::string> MountAliases::changedBases(const MountAliases &a, const MountAliases &b) {
    std::map<std::string, std::pair<const std::string *, const std::string *>> byMount;  // mount -> (a, b) alias
    for (const Entry &e : a.entries_) byMount[e.mountKey].first = &e.aliasKey;
    for (const Entry &e : b.entries_) byMount[e.mountKey].second = &e.aliasKey;
    std::vector<std::string> bases;
    for (const auto &[mount, aliasPair] : byMount) {
        const auto &[inA, inB] = aliasPair;
        if (inA && inB && *inA == *inB) continue;
        bases.push_back(a.rewritten(mount));
        bases.push_back(b.rewritten(mount));
    }
    return bases;
}

std::string MountAliases::describe() const {
    if (aliasCount_ == 0) return "no smbfs mounts";
    std::string out;
    for (const Entry &e : entries_) {
        if (e.aliasKey.empty()) continue;
        if (!out.empty()) out += "; ";
        out += e.mountKey + " -> " + e.aliasKey;
    }
    return out;
}

} // namespace intake
