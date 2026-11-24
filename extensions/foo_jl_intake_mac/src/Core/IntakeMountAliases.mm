//
//  IntakeMountAliases.mm
//  foo_jl_intake
//

#include "IntakeMountAliases.h"

#include "IntakePath.h"
#include "IntakeWatchSet.h"  // ShareLinkRead, mayResolvePath

#include <algorithm>
#include <map>
#include <utility>

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

// `key` is `mount` or lies under it (both normalized). A mount point is
// compared ignoring ASCII case (see the header), a link byte-exact
// (`foldCase` false); bytes past it are not compared here, and ASCII
// folding keeps lengths, so the caller's key.substr(mount.size()) is still
// the rest of `key`.
bool isUnder(std::string_view key, std::string_view mount, bool foldCase = true) {
    if (mount == "/") return !key.empty() && key[0] == '/';
    if (key.size() < mount.size() || (key.size() > mount.size() && key[mount.size()] != '/')) return false;
    if (!foldCase) return key.compare(0, mount.size(), mount) == 0;
    for (size_t i = 0; i < mount.size(); i++) {
        if (asciiLower(key[i]) != asciiLower(mount[i])) return false;
    }
    return true;
}

bool sameIgnoringCase(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); i++) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

std::string linkNote(const std::string &link, const char *why) {
    return "share link \"" + link + "\": " + why + "; ignored";
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
    return build(mounts, {});
}

std::shared_ptr<const MountAliases> MountAliases::build(const std::vector<MountEntry> &mounts,
                                                        const std::vector<ShareLinkRead> &links,
                                                        std::vector<std::string> *reasons) {
    auto table = std::make_shared<MountAliases>(Token{});
    if (reasons) reasons->assign(links.size(), std::string());

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

    // B11: share links (see the header). The table holds only mount entries
    // here, so rewritten() gives a target's key through the smbfs entries.
    std::map<std::string, LinkEntry> byLink;  // by linkKey: one entry per link, in a fixed order
    std::string linkKey;
    std::string targetNorm;
    for (size_t i = 0; i < links.size(); i++) {
        const ShareLinkRead &read = links[i];
        auto ignore = [&](const char *why) {
            table->notes_.push_back(linkNote(read.linkPath, why));
            if (reasons) (*reasons)[i] = why;
        };
        if (read.status != ShareLinkStatus::Link) {
            ignore(shareLinkStatusText(read.status));
            continue;
        }
        if (normalizePath(read.linkPath, linkKey) != PathStatus::Ok) {
            ignore("not an absolute path");
            continue;
        }
        // "/" would put every key under the link.
        if (linkKey == "/") {
            ignore("the root folder");
            continue;
        }
        // A mount point is no symlink; an entry for one would merge with or
        // shadow that mount's own entry.
        bool isMountPoint = false;
        for (const auto &[mount, alias] : byMount) {
            if (sameIgnoringCase(linkKey, mount)) {
                isMountPoint = true;
                break;
            }
        }
        if (isMountPoint) {
            ignore("a mount point");
            continue;
        }
        // readShareLink never reports Link there; a table built from other
        // reads still must not shadow a share's own entry with one.
        if (!mayResolvePath(read.linkPath, mounts)) {
            ignore("on a network volume");
            continue;
        }
        if (normalizePath(read.rawTarget, targetNorm) != PathStatus::Ok) {
            ignore("its target is not an absolute path");
            continue;
        }
        if (byLink.count(linkKey)) continue;  // the same link twice (NFC and NFD spellings): the first wins
        LinkEntry link;
        link.linkKey = linkKey;
        link.rawLink = read.linkPath;
        link.rawTarget = read.rawTarget;
        link.targetKey = table->rewritten(targetNorm);
        for (const Entry &e : table->entries_) {
            if (!isUnder(targetNorm, e.mountKey)) continue;
            link.onShare = !e.aliasKey.empty();  // a nested mount that is not smbfs: off the share
            break;
        }
        if (!link.onShare) {
            table->notes_.push_back("share link \"" + link.rawLink + "\" points at \"" + link.rawTarget +
                                    "\", not at a mounted share: its rows match only intake roots there");
        }
        byLink.emplace(linkKey, std::move(link));
    }
    if (byLink.empty() && table->notes_.empty()) return table;
    for (auto &[key, link] : byLink) {
        table->entries_.push_back({link.linkKey, link.targetKey, false, link.onShare});
        table->links_.push_back(std::move(link));
    }
    // Longest first again; equal lengths by path, a mount point before a
    // link, so the order is a function of the entries alone.
    std::stable_sort(table->entries_.begin(), table->entries_.end(), [](const Entry &a, const Entry &b) {
        if (a.mountKey.size() != b.mountKey.size()) return a.mountKey.size() > b.mountKey.size();
        if (a.mountKey != b.mountKey) return a.mountKey < b.mountKey;
        return a.foldCase && !b.foldCase;
    });
    std::sort(table->notes_.begin(), table->notes_.end());
    return table;
}

std::shared_ptr<const MountAliases> MountAliases::none() {
    static const std::shared_ptr<const MountAliases> empty = std::make_shared<MountAliases>(Token{});
    return empty;
}

std::string_view MountAliases::rewrite(std::string_view key, std::string &buffer) const {
    for (const Entry &e : entries_) {
        if (!isUnder(key, e.mountKey, e.foldCase)) continue;
        if (e.aliasKey.empty()) return key;  // a nested mount that is not smbfs
        std::string_view rest = e.mountKey == "/" ? key : key.substr(e.mountKey.size());
        if (rest == "/") rest = std::string_view();
        if (e.aliasKey == "/") {
            // A link to "/": the rest is the key ("/" + "/a" would be "//a").
            buffer.assign(rest.empty() ? std::string_view("/") : rest);
            return buffer;
        }
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
    if (entries_.size() != other.entries_.size() || links_.size() != other.links_.size() ||
        notes_ != other.notes_) {
        return false;
    }
    for (size_t i = 0; i < entries_.size(); i++) {
        const Entry &x = entries_[i];
        const Entry &y = other.entries_[i];
        if (x.mountKey != y.mountKey || x.aliasKey != y.aliasKey || x.foldCase != y.foldCase ||
            x.onShare != y.onShare) {
            return false;
        }
    }
    // Every field, the raw spellings included: Swap reads them.
    for (size_t i = 0; i < links_.size(); i++) {
        const LinkEntry &x = links_[i];
        const LinkEntry &y = other.links_[i];
        if (x.linkKey != y.linkKey || x.rawLink != y.rawLink || x.rawTarget != y.rawTarget ||
            x.targetKey != y.targetKey || x.onShare != y.onShare) {
            return false;
        }
    }
    return true;
}

std::vector<std::string> MountAliases::changedBases(const MountAliases &a, const MountAliases &b) {
    // (path, folds case) -> (a, b) entry: a link never merges with a mount
    // point spelled alike.
    std::map<std::pair<std::string, bool>, std::pair<const Entry *, const Entry *>> byPath;
    for (const Entry &e : a.entries_) byPath[{e.mountKey, e.foldCase}].first = &e;
    for (const Entry &e : b.entries_) byPath[{e.mountKey, e.foldCase}].second = &e;
    std::vector<std::string> bases;
    for (const auto &[path, entryPair] : byPath) {
        const auto &[inA, inB] = entryPair;
        if (inA && inB && inA->aliasKey == inB->aliasKey && inA->onShare == inB->onShare) continue;
        bases.push_back(a.rewritten(path.first));
        bases.push_back(b.rewritten(path.first));
    }
    return bases;
}

std::string MountAliases::describe() const {
    if (aliasCount_ == 0 && links_.empty()) return "no smbfs mounts";
    std::string out = aliasCount_ == 0 ? "no smbfs mounts" : "";
    for (const Entry &e : entries_) {
        if (e.aliasKey.empty() || !e.foldCase) continue;
        if (!out.empty()) out += "; ";
        out += e.mountKey + " -> " + e.aliasKey;
    }
    for (const LinkEntry &link : links_) {
        out += "; link " + link.rawLink + " -> " + link.targetKey +
               (link.onShare ? " (exact case, on a share)" : " (exact case, not on a share)");
    }
    return out;
}

bool MountAliases::underOffShareLink(std::string_view key) const {
    for (const Entry &e : entries_) {
        if (!isUnder(key, e.mountKey, e.foldCase)) continue;
        if (!e.foldCase) return !e.onShare;  // the link entry rewrite() uses
        break;
    }
    // A link's path in another ASCII letter case (/Users/x/music for a link
    // configured as /Users/x/Music): rewrite() maps it through no link, yet
    // on a case-insensitive volume it is that same link, so what it plays
    // is not known either.
    for (const LinkEntry &link : links_) {
        if (isUnder(key, link.linkKey)) return true;
    }
    return false;
}

ShareLinkSummary summarizeShareLink(const ShareLinkRead &read, const std::vector<MountEntry> &mounts) {
    // The table the loader would build from this one read, so the flag
    // follows exactly its rules.
    std::vector<std::string> reasons;
    const std::shared_ptr<const MountAliases> table = MountAliases::build(mounts, {read}, &reasons);
    ShareLinkSummary out;
    if (!table->links().empty()) {
        const MountAliases::LinkEntry &link = table->links().front();
        out.used = true;
        out.onShare = link.onShare;
        out.text = "\xE2\x86\x92 " + link.rawTarget;  // "→ "
        if (link.onShare && link.targetKey.compare(0, kSmbAliasPrefix.size(), kSmbAliasPrefix) == 0) {
            const std::string_view share = std::string_view(link.targetKey).substr(kSmbAliasPrefix.size());
            out.text += " (share " + std::string(share.substr(0, share.find('/'))) + ")";
        } else {
            out.text += " (not on a share)";
        }
        return out;
    }
    out.text = reasons.empty() ? std::string(shareLinkStatusText(read.status)) : reasons.front();
    // A plain status says it all; anything else read fine but is not used.
    const bool plain = read.status == ShareLinkStatus::NotLink || read.status == ShareLinkStatus::Missing ||
                       read.status == ShareLinkStatus::Loop;
    if (!plain) out.text += ": ignored";
    return out;
}

} // namespace intake
