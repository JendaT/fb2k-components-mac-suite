//
//  IntakeSidecarMembers.mm
//  foo_jl_intake
//

#include "IntakeSidecarMembers.h"

#include "IntakeEnvelope.h"
#include "IntakeLog.h"
#include "IntakePath.h"
#include "IntakeStatusModel.h"

#import <Foundation/Foundation.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#include <unordered_set>

namespace intake {

namespace {

constexpr size_t kMaxSidecarBytes = 16u * 1024u * 1024u;

class PosixSidecarFileAccess final : public SidecarFileAccess {
public:
    bool listDirectory(const std::string &directory, std::vector<std::string> &names) override {
        names.clear();
        DIR *dir = opendir(directory.c_str());
        if (!dir) return false;
        bool ok = true;
        while (true) {
            errno = 0;
            struct dirent *entry = readdir(dir);
            if (!entry) {
                ok = errno == 0;  // NULL with errno set is an error, else the end
                break;
            }
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
            names.emplace_back(entry->d_name, entry->d_namlen);
        }
        closedir(dir);
        if (!ok) names.clear();
        return ok;
    }

    bool readFile(const std::string &path, std::string &contents) override {
        contents.clear();
        const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) return false;
        char buffer[16384];
        bool ok = true;
        while (true) {
            const ssize_t n = ::read(fd, buffer, sizeof buffer);
            if (n == 0) break;
            if (n < 0) {
                if (errno == EINTR) continue;
                ok = false;
                break;
            }
            if (contents.size() + static_cast<size_t>(n) > kMaxSidecarBytes) {
                ok = false;
                break;
            }
            contents.append(buffer, static_cast<size_t>(n));
        }
        ::close(fd);
        if (!ok) contents.clear();
        return ok;
    }
};

std::string_view trimmedJson(std::string_view s) {
    auto space = [](char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; };
    size_t begin = 0, end = s.size();
    while (begin < end && space(s[begin])) begin++;
    while (end > begin && space(s[end - 1])) end--;
    return s.substr(begin, end - begin);
}

std::string joinPath(const std::string &directory, const std::string &name) {
    if (!directory.empty() && directory.back() == '/') return directory + name;
    return directory + "/" + name;
}

// What a root gets without a listing: one root alone in its directory is
// taken as whole-directory; several share it and are virtual for certain.
RootMembers assumedMembers(bool sharedDirectory) {
    RootMembers m;
    m.kind = sharedDirectory ? MemberKind::None : MemberKind::WholeDirectory;
    m.source = MemberSource::Assumed;
    return m;
}

const RootMembers *previousFor(const MemberTable *previous, const std::string &id) {
    if (!previous) return nullptr;
    auto it = previous->find(id);
    return it == previous->end() ? nullptr : &it->second;
}

struct DirectoryGroup {
    const std::string *ioPath = nullptr;  // the first record's rootPath
    std::vector<const IntakeRecord *> roots;
    bool needsMembers = false;
};

} // anonymous namespace

SidecarFileAccess &posixSidecarFileAccess() {
    static PosixSidecarFileAccess access;
    return access;
}

std::string namedSidecarName(std::string_view id) {
    std::string name = ".intake.";
    name.append(id.data(), id.size());
    name += ".json";
    return name;
}

bool isSafeRelativePath(std::string_view path) {
    if (path.empty() || path.front() == '/') return false;
    if (path.find('\0') != std::string_view::npos || path.find('\\') != std::string_view::npos) {
        return false;
    }
    size_t start = 0;
    while (true) {
        const size_t slash = path.find('/', start);
        const std::string_view segment =
            path.substr(start, slash == std::string_view::npos ? std::string_view::npos : slash - start);
        if (segment.empty() || segment == "." || segment == "..") return false;
        if (slash == std::string_view::npos) return true;
        start = slash + 1;
    }
}

bool parseSidecarMemberPaths(std::string_view json, std::vector<std::string> &paths) {
    paths.clear();
    const std::string_view text = trimmedJson(json);
    if (text.empty()) return false;
    bool ok = true;
    @autoreleasepool {
        id root = parseJsonValue(text);
        id files = [root isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)root)[@"files"] : nil;
        if (![files isKindOfClass:[NSArray class]]) {
            ok = false;
        } else {
            paths.reserve([files count]);
            std::string path;
            for (id entry in (NSArray *)files) {
                id value = [entry isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)entry)[@"path"] : nil;
                if (![value isKindOfClass:[NSString class]]) {
                    ok = false;
                    break;
                }
                copyUTF8(value, path);
                if (!isSafeRelativePath(path)) {
                    ok = false;
                    break;
                }
                paths.push_back(path);
            }
        }
    }
    if (!ok) paths.clear();
    return ok;
}

MemberTable loadMembers(const std::vector<IntakeRecord> &records,
                        SidecarFileAccess &fs,
                        const MemberTable *previous,
                        const std::function<bool(const IntakeRecord &)> &needsMembers,
                        MemberLoadStats *statsOut) {
    MemberLoadStats stats;
    MemberTable table;
    table.reserve(records.size());

    auto wants = [&](const IntakeRecord &r) { return !needsMembers || needsMembers(r); };

    // Group by match key, so virtual roots sharing a directory (and NFC/NFD
    // spellings of one directory) cost one listing.
    std::unordered_map<std::string_view, size_t> groupOf;
    groupOf.reserve(records.size());
    std::vector<DirectoryGroup> groups;
    for (const IntakeRecord &r : records) {
        if (r.rootKey.empty()) {
            table[r.id] = assumedMembers(true);  // unmatchable anyway
            continue;
        }
        auto [it, inserted] = groupOf.try_emplace(std::string_view(r.rootKey), groups.size());
        if (inserted) {
            groups.emplace_back();
            groups.back().ioPath = &r.rootPath;
        }
        DirectoryGroup &g = groups[it->second];
        g.roots.push_back(&r);
        if (wants(r)) g.needsMembers = true;
    }
    stats.directories = groups.size();

    std::vector<std::string> names;
    std::string contents;
    for (const DirectoryGroup &g : groups) {
        const bool shared = g.roots.size() > 1;
        if (!g.needsMembers) {
            stats.directoriesSkipped++;
            for (const IntakeRecord *r : g.roots) table[r->id] = assumedMembers(shared);
            continue;
        }

        stats.directoriesListed++;
        if (!fs.listDirectory(*g.ioPath, names)) {
            stats.listFailures++;
            logInfo("members: cannot list " + *g.ioPath + "; keeping the previous members");
            for (const IntakeRecord *r : g.roots) {
                if (const RootMembers *prev = previousFor(previous, r->id)) {
                    RootMembers kept = *prev;
                    kept.source = MemberSource::Previous;
                    table[r->id] = std::move(kept);
                    stats.keptPrevious++;
                } else {
                    table[r->id] = assumedMembers(shared);
                }
            }
            continue;
        }

        std::unordered_set<std::string_view> present(names.begin(), names.end());
        for (const IntakeRecord *r : g.roots) {
            const std::string sidecar = namedSidecarName(r->id);
            RootMembers m;
            m.source = MemberSource::Listed;
            if (present.find(sidecar) == present.end()) {
                m.kind = MemberKind::WholeDirectory;
                table[r->id] = std::move(m);
                continue;
            }
            if (!wants(*r)) {
                // Virtual, but it renders nothing: the read is not worth it.
                m.kind = MemberKind::None;
                table[r->id] = std::move(m);
                continue;
            }

            const std::string path = joinPath(*g.ioPath, sidecar);
            bool parsed = false;
            for (int attempt = 0; attempt < 2 && !parsed; attempt++) {
                if (attempt > 0) stats.sidecarRetries++;
                stats.sidecarReads++;
                parsed = fs.readFile(path, contents) && parseSidecarMemberPaths(contents, m.relativePaths);
            }
            if (parsed) {
                m.kind = MemberKind::Members;
                table[r->id] = std::move(m);
                continue;
            }

            stats.sidecarFailures++;
            const RootMembers *prev = previousFor(previous, r->id);
            if (prev && prev->kind == MemberKind::Members) {
                RootMembers kept = *prev;
                kept.source = MemberSource::Previous;
                table[r->id] = std::move(kept);
                stats.keptPrevious++;
                logInfo("members: unreadable " + path + " after a retry; keeping the previous list");
            } else {
                m.kind = MemberKind::None;
                m.relativePaths.clear();
                table[r->id] = std::move(m);
                logInfo("members: unreadable " + path + " after a retry; the root matches nothing");
            }
        }
    }

    if (statsOut) *statsOut = stats;
    return table;
}

} // namespace intake
