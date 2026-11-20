//
//  IntakeSwapPlanner.mm
//  foo_jl_intake
//

#include "IntakeSwapPlanner.h"

#include "IntakeEnvelope.h"
#include "IntakePath.h"
#include "IntakeSidecarMembers.h"
#include "IntakeStatusModel.h"

#include <algorithm>
#include <cerrno>
#include <cstring>

namespace intake {

namespace {

std::string_view trimmedJson(std::string_view s) {
    auto space = [](char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; };
    size_t begin = 0, end = s.size();
    while (begin < end && space(s[begin])) begin++;
    while (end > begin && space(s[end - 1])) end--;
    return s.substr(begin, end - begin);
}

std::string joinPath(std::string_view directory, std::string_view name) {
    std::string out(directory);
    if (out.empty() || out.back() != '/') out += '/';
    out.append(name.data(), name.size());
    return out;
}

// The JSON boolean true (an NSNumber 1 does not count).
bool isJsonTrue(id value) {
    return [value isKindOfClass:[NSNumber class]] &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && [value boolValue];
}

char asciiLower(char c) {
    return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
}

bool equalsIgnoringAsciiCase(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); i++) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

// `path` is `mount` or lies under it, the mount point compared ignoring
// ASCII case (IntakeMountAliases' rule). Both lexically clean.
bool underMount(std::string_view path, std::string_view mount) {
    if (mount == "/") return !path.empty() && path[0] == '/';
    if (path.size() < mount.size()) return false;
    if (path.size() > mount.size() && path[mount.size()] != '/') return false;
    return equalsIgnoringAsciiCase(path.substr(0, mount.size()), mount);
}

// `key` is `share` or lies under it: the share name (up to the first '/')
// ignoring ASCII case (smbShareKey lowercases it), the rest byte for byte.
bool underShare(std::string_view key, std::string_view share) {
    if (key.size() < share.size()) return false;
    if (key.size() > share.size() && key[share.size()] != '/') return false;
    const size_t nameEnd = std::min(share.find('/'), share.size());
    if (!equalsIgnoringAsciiCase(key.substr(0, nameEnd), share.substr(0, nameEnd))) return false;
    return key.substr(nameEnd, share.size() - nameEnd) == share.substr(nameEnd);
}

bool readAndParse(SidecarFileAccess &fs, const std::string &path, std::vector<SidecarFile> &files, std::string &docId,
                  bool &isVirtual, int &error, bool &missing) {
    missing = false;
    for (int attempt = 0; attempt < 2; attempt++) {
        std::string contents;
        error = 0;
        if (!fs.readFile(path, contents, error)) {
            if (error == ENOENT || error == ENOTDIR) {
                missing = true;
                return false;
            }
            if (isShareUnreachableError(error)) return false;  // no retry on a share that is gone
            continue;
        }
        if (parseSidecarFiles(contents, files, &docId, &isVirtual)) return true;
        error = 0;
    }
    return false;
}

} // anonymous namespace

bool parseSidecarFiles(std::string_view json, std::vector<SidecarFile> &files, std::string *docId, bool *isVirtual) {
    files.clear();
    if (docId) docId->clear();
    if (isVirtual) *isVirtual = false;
    const std::string_view text = trimmedJson(json);
    if (text.empty()) return false;
    bool ok = true;
    @autoreleasepool {
        id root = parseJsonValue(text);
        if (![root isKindOfClass:[NSDictionary class]]) return false;
        NSDictionary *doc = (NSDictionary *)root;
        id list = doc[@"files"];
        if (![list isKindOfClass:[NSArray class]]) return false;
        files.reserve([list count]);
        for (id entry in (NSArray *)list) {
            if (![entry isKindOfClass:[NSDictionary class]]) {
                ok = false;
                break;
            }
            id value = ((NSDictionary *)entry)[@"path"];
            if (![value isKindOfClass:[NSString class]]) {
                ok = false;
                break;
            }
            SidecarFile f;
            copyUTF8(value, f.path);
            if (!isSafeRelativePath(f.path)) {
                ok = false;
                break;
            }
            id shadow = ((NSDictionary *)entry)[@"quality_shadow"];
            f.shadow = isJsonTrue(shadow);
            files.push_back(std::move(f));
        }
        if (ok && docId) {
            id value = doc[@"id"];
            if ([value isKindOfClass:[NSString class]]) copyUTF8(value, *docId);
        }
        if (ok && isVirtual) *isVirtual = isJsonTrue(doc[@"virtual"]);
    }
    if (!ok) files.clear();
    return ok;
}

bool readPlacedRootFiles(const IntakeRecord &record, SidecarFileAccess &fs, PlacedRootFiles &out, std::string &error,
                         int *errnoOut) {
    if (errnoOut) *errnoOut = 0;
    error.clear();
    if (record.rootPath.empty()) {
        error = "no root path";
        return false;
    }
    std::vector<SidecarFile> files;
    std::string docId;
    bool isVirtual = false;
    int err = 0;
    bool missing = false;
    std::string path = joinPath(record.rootPath, namedSidecarName(record.id));
    bool read = readAndParse(fs, path, files, docId, isVirtual, err, missing);
    if (!read && missing) {
        path = joinPath(record.rootPath, ".intake.json");
        read = readAndParse(fs, path, files, docId, isVirtual, err, missing);
    }
    if (errnoOut) *errnoOut = err;
    if (!read) {
        if (missing) {
            error = "no sidecar for " + record.id + " in " + record.rootPath;
        } else if (err != 0) {
            error = "cannot read " + path + " (" + strerror(err) + ")";
        } else {
            error = "unusable sidecar " + path;
        }
        return false;
    }
    if (docId != record.id) {
        error = path + " belongs to " + (docId.empty() ? std::string("no id") : docId) + ", not " + record.id;
        return false;
    }
    out.id = record.id;
    out.rootPath = record.rootPath;
    out.rootKey = record.rootKey;
    out.targetPath = record.placedTargetPath;
    out.wholeFolder = !isVirtual;
    out.files = std::move(files);
    return true;
}

LibraryPrefix makeLibraryPrefix(std::string_view from, std::string_view to) {
    LibraryPrefix p;
    p.from = normalizedPrefix(from);
    p.to = normalizedPrefix(to);
    p.check = validatePrefixPair(p.from, p.to);
    return p;
}

PrefixRewrite rewriteLibraryPrefix(const LibraryPrefix &prefix, std::string_view path, std::string &out) {
    out.assign(path.data(), path.size());
    if (!prefix.active()) return PrefixRewrite::NoMapping;
    const std::string &from = prefix.from;
    const bool under = path.size() >= from.size() && path.compare(0, from.size(), from) == 0 &&
                       (path.size() == from.size() || path[from.size()] == '/');
    if (!under) return PrefixRewrite::OutsidePair;
    std::string rewritten = prefix.to;
    rewritten.append(path.substr(from.size()));
    out = std::move(rewritten);
    return PrefixRewrite::Rewritten;
}

const char *swapSkipText(SwapSkip skip) {
    switch (skip) {
        case SwapSkip::None: return "swapped";
        case SwapSkip::NotPlaced: return "root no longer placed and verified";
        case SwapSkip::NoTarget: return "no placed target path";
        case SwapSkip::SidecarUnreadable: return "sidecar unreadable";
        case SwapSkip::NotInSidecar: return "not in the sidecar";
        case SwapSkip::Shadow: return "shadow";
        case SwapSkip::LibraryMissing: return "library file missing";
        case SwapSkip::ShareUnreachable: return "library share unreachable";
        case SwapSkip::NoMatchingMount: return "no matching mount";
        case SwapSkip::LinkOffShare: return "the share link does not lead to the library copy";
        case SwapSkip::SlowConversion: return "path conversion too slow";
        case SwapSkip::PlaylistGone: return "playlist gone";
        case SwapSkip::PlaylistLocked: return "playlist locked";
        case SwapSkip::RowGone: return "row no longer in the playlist";
        case SwapSkip::ReplaceRefused: return "replace refused";
        case SwapSkip::Count: break;
    }
    return "unknown";
}

long matchSidecarFile(const PlacedRootFiles &root, std::string_view itemKey) {
    if (root.rootKey.empty() || itemKey.empty()) return -1;
    std::string normalizedItem;
    if (normalizePath(itemKey, normalizedItem) != PathStatus::Ok) return -1;
    std::string joined;
    std::string normalized;
    for (size_t i = 0; i < root.files.size(); i++) {
        joined = joinPath(root.rootKey, root.files[i].path);
        if (normalizePath(joined, normalized) != PathStatus::Ok) continue;
        if (normalized == normalizedItem) return static_cast<long>(i);
    }
    return -1;
}

bool libraryPathFor(const PlacedRootFiles &root, size_t index, const LibraryPrefix &prefix, std::string &out,
                    PrefixRewrite *rewrite) {
    out.clear();
    if (index >= root.files.size()) return false;
    const std::string target = lexicalAbsolutePath(root.targetPath);
    if (target.empty()) return false;
    const std::string joined = lexicalAbsolutePath(joinPath(target, root.files[index].path));
    if (joined.empty()) return false;
    const PrefixRewrite r = rewriteLibraryPrefix(prefix, joined, out);
    if (rewrite) *rewrite = r;
    return true;
}

SwapPlan planSwap(const PlacedRootFiles &root, std::string_view itemKey, const LibraryPrefix &prefix) {
    SwapPlan plan;
    if (lexicalAbsolutePath(root.targetPath).empty()) {
        plan.skip = SwapSkip::NoTarget;
        return plan;
    }
    const long index = matchSidecarFile(root, itemKey);
    if (index < 0) {
        plan.skip = SwapSkip::NotInSidecar;
        return plan;
    }
    const SidecarFile &f = root.files[static_cast<size_t>(index)];
    plan.relativePath = f.path;
    if (f.shadow) {
        plan.skip = SwapSkip::Shadow;
        return plan;
    }
    if (!libraryPathFor(root, static_cast<size_t>(index), prefix, plan.libraryPath, &plan.rewrite)) {
        plan.skip = SwapSkip::NoTarget;
    }
    return plan;
}

std::vector<std::string> aliasMountPaths(const std::vector<MountEntry> &mounts, std::string_view path) {
    std::vector<std::string> out;
    out.emplace_back(path);
    const std::string clean = lexicalAbsolutePath(path);
    if (clean.empty()) return out;

    // The mount that owns `path`: the longest mount point containing it
    // (a later row for the same mount point is stacked on top and wins).
    const MountEntry *owner = nullptr;
    std::string ownerPoint;
    for (const MountEntry &m : mounts) {
        const std::string point = lexicalAbsolutePath(m.mountPoint);
        if (point.empty() || !underMount(clean, point)) continue;
        if (owner == nullptr || point.size() >= ownerPoint.size()) {
            owner = &m;
            ownerPoint = point;
        }
    }
    if (owner == nullptr || owner->fsType != "smbfs") return out;
    const std::string share = smbShareKey(owner->source);
    if (share.empty()) return out;
    std::string_view rest = std::string_view(clean).substr(ownerPoint == "/" ? 0 : ownerPoint.size());
    const std::string key = share + std::string(rest);  // "<share>[/sub]/<rest>"

    for (const MountEntry &m : mounts) {
        if (&m == owner || m.fsType != "smbfs") continue;
        const std::string otherShare = smbShareKey(m.source);
        if (otherShare.empty() || !underShare(key, otherShare)) continue;
        const std::string point = lexicalAbsolutePath(m.mountPoint);
        if (point.empty()) continue;
        std::string candidate = point == "/" ? std::string() : point;
        candidate += key.substr(otherShare.size());
        if (candidate.empty()) candidate = "/";
        bool seen = false;
        for (const std::string &have : out) seen = seen || have == candidate;
        if (!seen) out.push_back(std::move(candidate));
    }
    return out;
}

std::string otherNormalizationForm(std::string_view path) {
    if (path.empty()) return std::string();
    bool ascii = true;
    for (char c : path) ascii = ascii && static_cast<unsigned char>(c) < 0x80;
    if (ascii) return std::string();
    std::string out;
    @autoreleasepool {
        NSString *s = [[NSString alloc] initWithBytes:path.data() length:path.size() encoding:NSUTF8StringEncoding];
        if (s == nil) return std::string();
        NSString *nfc = s.precomposedStringWithCanonicalMapping;
        std::string nfcBytes;
        copyUTF8(nfc, nfcBytes);
        if (nfcBytes != path) {
            out = std::move(nfcBytes);
        } else {
            copyUTF8(s.decomposedStringWithCanonicalMapping, out);
            if (out == path) out.clear();
        }
    }
    return out;
}

std::string canonicalVolumePrefix(std::string_view path) {
    static constexpr std::string_view kFile = "file://";
    static constexpr std::string_view kMacVolume = "mac-volume://";
    if (path.size() >= kMacVolume.size() && equalsIgnoringAsciiCase(path.substr(0, kMacVolume.size()), kMacVolume)) {
        const size_t slash = path.find('/', kMacVolume.size());
        if (slash == std::string_view::npos || slash == kMacVolume.size()) return std::string();
        return std::string(path.substr(0, slash + 1));
    }
    if (path.size() >= kFile.size() && equalsIgnoringAsciiCase(path.substr(0, kFile.size()), kFile)) {
        return std::string(kFile);
    }
    return std::string();
}

bool sameVolumePrefix(std::string_view a, std::string_view b) {
    return !a.empty() && equalsIgnoringAsciiCase(a, b);
}

std::string owningMountPoint(const std::vector<MountEntry> &mounts, std::string_view path) {
    const std::string clean = lexicalAbsolutePath(path);
    if (clean.empty()) return std::string();
    std::string owner;
    bool found = false;
    for (const MountEntry &m : mounts) {
        const std::string point = lexicalAbsolutePath(m.mountPoint);
        if (point.empty() || !underMount(clean, point)) continue;
        if (!found || point.size() >= owner.size()) {
            owner = point;
            found = true;
        }
    }
    return owner;
}

bool pathUnderMountPoint(std::string_view path, std::string_view mountPoint) {
    static constexpr std::string_view kFile = "file://";
    if (path.size() >= kFile.size() && equalsIgnoringAsciiCase(path.substr(0, kFile.size()), kFile)) {
        path.remove_prefix(kFile.size());
    }
    const std::string clean = lexicalAbsolutePath(path);
    const std::string point = lexicalAbsolutePath(mountPoint);
    return !clean.empty() && !point.empty() && underMount(clean, point);
}

void noteVolumeForm(std::vector<std::string> &forms, std::string_view path) {
    std::string form = canonicalVolumePrefix(path);
    if (form.empty()) return;
    for (const std::string &have : forms) {
        if (sameVolumePrefix(have, form)) return;
    }
    forms.push_back(std::move(form));
}

bool hasVolumeForm(const std::vector<std::string> &forms, std::string_view path) {
    const std::string form = canonicalVolumePrefix(path);
    if (form.empty()) return false;
    for (const std::string &have : forms) {
        if (sameVolumePrefix(have, form)) return true;
    }
    return false;
}

long chooseCanonicalCandidate(const std::vector<CanonicalCandidate> &candidates,
                              const std::vector<std::string> &playlistForms) {
    for (size_t i = 0; i < candidates.size(); i++) {
        if (hasVolumeForm(playlistForms, candidates[i].form)) return static_cast<long>(i);
    }
    for (size_t i = 0; i < candidates.size(); i++) {
        if (candidates[i].roundTrips && !canonicalVolumePrefix(candidates[i].form).empty()) {
            return static_cast<long>(i);
        }
    }
    return -1;
}

void noteLinkForm(PlaylistLinkForms &forms, const std::vector<MountAliases::LinkEntry> &links,
                  std::string_view path, std::string &buffer) {
    static constexpr std::string_view kFile = "file://";
    if (links.empty() || path.size() <= kFile.size() ||
        !equalsIgnoringAsciiCase(path.substr(0, kFile.size()), kFile)) {
        return;
    }
    std::string_view key;
    if (normalizePath(path, buffer, key) != PathStatus::Ok) return;
    const MountAliases::LinkEntry *holder = nullptr;
    for (const MountAliases::LinkEntry &link : links) {
        const std::string &l = link.linkKey;
        if (l.empty() || l == "/" || (holder != nullptr && l.size() <= holder->linkKey.size())) continue;
        if (key.size() >= l.size() && key.compare(0, l.size(), l) == 0 &&
            (key.size() == l.size() || key[l.size()] == '/')) {
            holder = &link;
        }
    }
    if (holder == nullptr) return;
    if (std::find(forms.links.begin(), forms.links.end(), holder->linkKey) == forms.links.end()) {
        forms.links.push_back(holder->linkKey);
    }
    forms.items.emplace(std::string(key), std::string(path));
}

LinkForm linkFormFor(const std::vector<std::string> &candidates, const std::vector<MountAliases::LinkEntry> &links,
                     const std::vector<std::string> &linkForms) {
    LinkForm out;
    std::vector<const MountAliases::LinkEntry *> noted;
    for (const std::string &linkKey : linkForms) {
        for (const MountAliases::LinkEntry &link : links) {
            if (link.linkKey == linkKey) {
                noted.push_back(&link);
                break;
            }
        }
    }
    if (noted.empty()) return out;
    for (size_t i = 0; i < candidates.size(); i++) {
        const std::string &candidate = candidates[i];
        if (candidate.empty() || candidate[0] != '/') continue;
        for (const MountAliases::LinkEntry *link : noted) {
            const std::string rawLink = lexicalAbsolutePath(link->rawLink);
            const std::string target = lexicalAbsolutePath(link->rawTarget);
            if (rawLink.empty() || rawLink == "/") continue;  // MountAliases never maps "/"
            // The bytes past the target ("/" holds the whole path), or past
            // the link when the candidate is already spelled through it.
            std::string_view rest;
            if (!target.empty() && underMount(candidate, target)) {
                rest = std::string_view(candidate).substr(target == "/" ? 0 : target.size());
            } else if (candidate.size() >= rawLink.size() && candidate.compare(0, rawLink.size(), rawLink) == 0 &&
                       (candidate.size() == rawLink.size() || candidate[rawLink.size()] == '/')) {
                rest = std::string_view(candidate).substr(rawLink.size());
            } else {
                continue;
            }
            out.path = "file://" + rawLink;
            out.path.append(rest.data(), rest.size());
            out.candidateIndex = static_cast<long>(i);
            return out;
        }
    }
    return out;
}

std::string linkSpellingFor(const PlaylistLinkForms &forms, const std::string &path) {
    if (forms.items.empty()) return path;
    std::string key;
    if (normalizePath(path, key) != PathStatus::Ok) return path;
    auto found = forms.items.find(key);
    return found == forms.items.end() ? path : found->second;
}

CensusEntry censusEntry(bool refused, bool offShareLink, bool income) {
    if (refused || offShareLink) return CensusEntry::Unchecked;
    return income ? CensusEntry::Income : CensusEntry::Clear;
}

size_t SwapTally::skippedTotal() const {
    size_t n = 0;
    for (size_t count : skipped) n += count;
    return n;
}

std::string swapResultLine(const SwapTally &tally) {
    std::string line = "swap: " + std::to_string(tally.swapped) + " row(s) swapped to library paths, " +
                       std::to_string(tally.skippedTotal()) + " skipped";
    std::string reasons;
    for (size_t i = 1; i < tally.skipped.size(); i++) {
        if (tally.skipped[i] == 0) continue;
        if (!reasons.empty()) reasons += ", ";
        reasons += std::to_string(tally.skipped[i]) + " " + swapSkipText(static_cast<SwapSkip>(i));
    }
    if (!reasons.empty()) line += " (" + reasons + ")";
    return line;
}

} // namespace intake
