#pragma once

//
// jl_dependency_core.h - the decisions behind installing a missing suite
// component from a dependent's preferences (JLDependencyGate,
// JLComponentInstaller): which GitHub release to take, its checksum, whether
// its archive may be unpacked, where downloads may come from, what the gate
// shows, and the note that carries the install across a restart.
//
// Plain C++17, no Foundation or SDK: unit tested standalone.
//

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>

namespace jl_dep {

// ---------------------------------------------------------------------------
// Versions: "1.2.3" (a leading "v" allowed)
// ---------------------------------------------------------------------------

struct Version {
    int major = 0, minor = 0, patch = 0;
    bool valid = false;
};

inline Version parseVersion(const std::string &text) {
    Version v;
    size_t i = 0;
    if (i < text.size() && (text[i] == 'v' || text[i] == 'V')) i++;
    int *parts[3] = { &v.major, &v.minor, &v.patch };
    for (int p = 0; p < 3; p++) {
        if (p > 0) {
            if (i >= text.size() || text[i] != '.') return Version{};
            i++;
        }
        const size_t start = i;
        long value = 0;
        while (i < text.size() && std::isdigit(static_cast<unsigned char>(text[i])) && i - start < 6) {
            value = value * 10 + (text[i] - '0');
            i++;
        }
        if (i == start) return Version{};
        *parts[p] = static_cast<int>(value);
    }
    if (i != text.size()) return Version{};
    v.valid = true;
    return v;
}

// <0, 0, >0 like strcmp; an invalid version sorts before every valid one
inline int compare(const Version &a, const Version &b) {
    if (a.valid != b.valid) return a.valid ? 1 : -1;
    if (a.major != b.major) return a.major < b.major ? -1 : 1;
    if (a.minor != b.minor) return a.minor < b.minor ? -1 : 1;
    if (a.patch != b.patch) return a.patch < b.patch ? -1 : 1;
    return 0;
}

inline std::string toString(const Version &v) {
    return std::to_string(v.major) + "." + std::to_string(v.minor) + "." + std::to_string(v.patch);
}

// ---------------------------------------------------------------------------
// Releases (GitHub's /releases list, one monorepo for the whole suite)
// ---------------------------------------------------------------------------

struct Asset {
    std::string name;
    uint64_t size = 0;
    std::string url;                // browser_download_url
};

struct Release {
    std::string tag;
    bool draft = false;
    bool prerelease = false;
    std::vector<Asset> assets;
};

inline constexpr const char *kChecksumAsset = "SHA256SUMS";

struct Pick {
    bool found = false;
    Version version;
    std::string tag;
    Asset package;
    Asset sums;
};

// Where GitHub serves a release asset of `repo` ("owner/name"): exactly this
// URL, so a release cannot point its downloads anywhere else
inline std::string releaseAssetURL(const std::string &repo, const std::string &tag, const std::string &asset) {
    return "https://github.com/" + repo + "/releases/download/" + tag + "/" + asset;
}

// The newest published release of one component in `repo`: tags exactly
// `tagPrefix` + "X.Y.Z", no drafts or prereleases, with both the package
// asset and SHA256SUMS served from the release's own download URLs. Never
// "the latest release" of the repository: that is whichever component was
// released last.
inline Pick pickRelease(const std::vector<Release> &releases, const std::string &repo, const std::string &tagPrefix,
                        const std::string &assetName) {
    Pick best;
    for (const Release &r : releases) {
        if (r.draft || r.prerelease || r.tag.compare(0, tagPrefix.size(), tagPrefix) != 0) continue;
        const Version v = parseVersion(r.tag.substr(tagPrefix.size()));
        if (!v.valid || r.tag.size() > tagPrefix.size() + 20) continue;
        const Asset *package = nullptr, *sums = nullptr;
        for (const Asset &a : r.assets) {
            if (a.name == assetName && a.url == releaseAssetURL(repo, r.tag, a.name)) package = &a;
            if (a.name == kChecksumAsset && a.url == releaseAssetURL(repo, r.tag, a.name)) sums = &a;
        }
        if (!package || !sums) continue;
        if (best.found && compare(v, best.version) <= 0) continue;
        best.found = true;
        best.version = v;
        best.tag = r.tag;
        best.package = *package;
        best.sums = *sums;
    }
    return best;
}

// The component's tags from GitHub's matching-refs list ("refs/tags/<tag>"),
// newest version first, at most `count`: the releases to look at, however
// many other components were released since
inline std::vector<std::string> newestTags(const std::vector<std::string> &refs, const std::string &tagPrefix,
                                           size_t count) {
    std::vector<std::pair<Version, std::string>> tags;
    const std::string head = "refs/tags/" + tagPrefix;
    for (const std::string &ref : refs) {
        if (ref.compare(0, head.size(), head) != 0 || ref.size() > head.size() + 20) continue;
        const Version v = parseVersion(ref.substr(head.size()));
        if (v.valid) tags.emplace_back(v, ref.substr(10));
    }
    std::sort(tags.begin(), tags.end(), [](const auto &a, const auto &b) { return compare(a.first, b.first) > 0; });
    std::vector<std::string> out;
    for (size_t i = 0; i < tags.size() && i < count; i++) out.push_back(tags[i].second);
    return out;
}

// ---------------------------------------------------------------------------
// Checksums: SHA256SUMS in shasum's format, "<64 hex>  <name>" (or " *<name>")
// ---------------------------------------------------------------------------

// The lowercase hex SHA-256 listed for `assetName`, or "" when it is not
// listed exactly once
inline std::string findSha256(const std::string &sums, const std::string &assetName) {
    std::istringstream in(sums);
    std::string line, found;
    int matches = 0;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.size() < 66) continue;
        std::string hex = line.substr(0, 64);
        bool isHex = true;
        for (char &c : hex) {
            c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            isHex &= std::isxdigit(static_cast<unsigned char>(c)) != 0;
        }
        if (!isHex || line[64] != ' ') continue;
        size_t at = 65;
        if (at < line.size() && (line[at] == ' ' || line[at] == '*')) at++;
        if (line.substr(at) != assetName) continue;
        found = hex;
        matches++;
    }
    return matches == 1 ? found : std::string();
}

// ---------------------------------------------------------------------------
// Where requests may go: HTTPS only, GitHub's API, its release download
// URLs and the hosts those redirect to. Not the rest of
// githubusercontent.com (raw., gist. serve anyone's files).
// ---------------------------------------------------------------------------

inline bool allowedDownloadHost(const std::string &scheme, const std::string &host) {
    if (scheme != "https") return false;
    std::string h = host;
    std::transform(h.begin(), h.end(), h.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return h == "github.com" || h == "api.github.com" || h == "objects.githubusercontent.com" ||
           h == "release-assets.githubusercontent.com";
}

// Downloads larger than this are refused (the BPM package is ~9 MB)
inline constexpr uint64_t kMaxDownloadBytes = 50ull * 1024 * 1024;

// ---------------------------------------------------------------------------
// The archive: only one component bundle under mac/, nothing else
// ---------------------------------------------------------------------------

struct ArchiveCheck {
    bool ok = false;
    std::string reason;             // why not, for the console
    size_t files = 0;
};

// From /usr/bin/zipinfo's default listing: every entry a plain file or a
// directory (no symlinks, nothing from another OS's attribute format),
// named mac/ or inside mac/<bundle>/, relative, without "..", backslashes
// or control characters. The bundle's executable must be there.
inline ArchiveCheck checkArchiveListing(const std::string &listing, const std::string &bundle,
                                        const std::string &executable) {
    ArchiveCheck out;
    const std::string root = "mac/", prefix = "mac/" + bundle + "/";
    const std::string exe = prefix + "Contents/MacOS/" + executable;
    bool haveExe = false;
    std::istringstream in(listing);
    std::string line;
    size_t entries = 0;
    auto fail = [&](const std::string &why) {
        out.ok = false;
        out.reason = why;
        return out;
    };
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.compare(0, 8, "Archive:") == 0 || line.compare(0, 14, "Zip file size:") == 0) continue;
        // The trailer: "<n> files, <bytes> bytes uncompressed, ..." ("1 file, ")
        if (!line.empty() && std::isdigit(static_cast<unsigned char>(line[0])) &&
            (line.find(" files, ") != std::string::npos || line.find(" file, ") != std::string::npos)) {
            continue;
        }
        if (line.empty()) continue;
        // "drwxr-xr-x  3.0 unx  0 bx stor 26-Nov-03 23:39 mac/": the type and
        // permissions, then 7 fields, then the name (which may hold spaces)
        if (line.size() < 11 || line[10] != ' ') return fail("unexpected listing line: " + line);
        const char type = line[0];
        if (type != '-' && type != 'd') return fail("not a plain file or folder: " + line);
        for (int i = 1; i < 10; i++) {
            const char c = line[i];
            if (c != 'r' && c != 'w' && c != 'x' && c != '-' && c != 's' && c != 'S' && c != 't' && c != 'T') {
                return fail("unexpected permissions: " + line);
            }
        }
        // Fields after the permissions: version, OS, size, text/binary,
        // method, date, time; the name follows the time after one space
        size_t pos = 10;
        std::string fields[7];
        for (int field = 0; field < 7; field++) {
            while (pos < line.size() && line[pos] == ' ') pos++;
            const size_t start = pos;
            while (pos < line.size() && line[pos] != ' ') pos++;
            fields[field] = line.substr(start, pos - start);
        }
        if (pos >= line.size() || fields[6].empty()) return fail("unexpected listing line: " + line);
        if (fields[1] != "unx") return fail("entry not from a Unix zip (" + fields[1] + "): " + line);
        const std::string name = line.substr(pos + 1);
        if (name.empty() || name[0] == '/' || name.find('\\') != std::string::npos) return fail("bad entry name: " + name);
        for (unsigned char c : name) {
            if (c < 0x20 || c == 0x7f) return fail("control character in an entry name");
        }
        // No ".." component anywhere
        std::istringstream parts(name);
        std::string part;
        while (std::getline(parts, part, '/')) {
            if (part == "..") return fail("entry leaves the folder: " + name);
        }
        const bool isDir = type == 'd';
        if (isDir && name.back() != '/') return fail("folder without a trailing slash: " + name);
        if (!isDir && name.back() == '/') return fail("file with a trailing slash: " + name);
        if (name == root ? !isDir : name.compare(0, prefix.size(), prefix) != 0) {
            return fail("entry outside " + prefix + ": " + name);
        }
        if (!isDir && name == exe) haveExe = (line[3] == 'x');
        entries++;
        if (!isDir) out.files++;
    }
    if (entries == 0) return fail("empty archive");
    if (!haveExe) return fail("no executable at " + exe);
    out.ok = true;
    return out;
}

// ---------------------------------------------------------------------------
// The gate's state
// ---------------------------------------------------------------------------

enum class GateState {
    Available,          // the dependency's service resolves: nothing to show
    Missing,            // not installed
    TooOld,             // installed, older than the dependent needs
    RestartPending,     // a new enough bundle is on disk but not loaded yet
    Working,            // looking up, downloading, verifying, installing
    Failed,             // the last attempt failed (message kept)
    BusyElsewhere,      // another dependent holds the install lock
};

// `onDisk`: the version of the bundle in user-components (invalid when
// there is none)
inline GateState gateState(bool serviceResolves, const Version &onDisk, const Version &minVersion, bool working,
                           bool failed, bool lockedByOther) {
    if (working) return GateState::Working;
    if (serviceResolves) return GateState::Available;
    if (lockedByOther) return GateState::BusyElsewhere;
    if (failed) return GateState::Failed;
    if (!onDisk.valid) return GateState::Missing;
    if (compare(onDisk, minVersion) < 0) return GateState::TooOld;
    return GateState::RestartPending;
}

// ---------------------------------------------------------------------------
// The resume note, kept in the configuration across the restart
// ---------------------------------------------------------------------------

struct ResumeNote {
    std::string component;          // "foo_jl_bpm"
    std::string pageGuid;           // the dependent's preferences page, "{...}"
    std::string dependent;          // who installed it ("Waveform Seekbar"): only it resumes
    std::string version;            // what was installed
    int64_t timestamp = 0;          // unix seconds when it was written
};

// A note older than this is dropped unread (the user restarted much later)
inline constexpr int64_t kResumeMaxAgeSeconds = 10 * 60;

inline std::string encodeResume(const ResumeNote &n) {
    return "v1|" + n.component + "|" + n.pageGuid + "|" + n.dependent + "|" + n.version + "|" +
           std::to_string(n.timestamp);
}

inline bool decodeResume(const std::string &text, ResumeNote &out) {
    std::vector<std::string> f;
    std::istringstream in(text);
    std::string part;
    while (std::getline(in, part, '|')) f.push_back(part);
    if (f.size() != 6 || f[0] != "v1" || f[1].empty()) return false;
    char *end = nullptr;
    const long long t = std::strtoll(f[5].c_str(), &end, 10);
    if (!end || *end != '\0' || f[5].empty()) return false;
    out.component = f[1];
    out.pageGuid = f[2];
    out.dependent = f[3];
    out.version = f[4];
    out.timestamp = t;
    return true;
}

// Whether a note read at `now` is still to be acted on
inline bool resumeIsFresh(const ResumeNote &n, int64_t now) {
    return n.timestamp <= now + 60 && now - n.timestamp <= kResumeMaxAgeSeconds;
}

} // namespace jl_dep
