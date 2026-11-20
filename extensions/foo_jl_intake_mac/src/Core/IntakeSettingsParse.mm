//
//  IntakeSettingsParse.mm
//  foo_jl_intake
//

#include "IntakeSettingsParse.h"

#include <sys/stat.h>
#include <unistd.h>

#include <unordered_set>

namespace intake {

namespace {

bool hasNul(std::string_view s) {
    return s.find('\0') != std::string_view::npos;
}

std::string_view trimmed(std::string_view s, const char *chars) {
    const size_t first = s.find_first_not_of(chars);
    if (first == std::string_view::npos) return std::string_view();
    const size_t last = s.find_last_not_of(chars);
    return s.substr(first, last - first + 1);
}

// The common start of every check: Empty, NotAbsolute, Missing, or Ok with
// `st` filled.
PathCheck statPath(const std::string &path, struct stat &st) {
    if (path.empty()) return PathCheck::Empty;
    if (path[0] != '/') return PathCheck::NotAbsolute;
    if (hasNul(path)) return PathCheck::Missing;
    if (stat(path.c_str(), &st) != 0) return PathCheck::Missing;
    return PathCheck::Ok;
}

} // anonymous namespace

std::string trimmedSetting(std::string_view text) {
    return std::string(trimmed(text, " \t\r\n"));
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

// --- folder lists ---

std::vector<FolderLine> parseFolderLines(std::string_view text) {
    std::vector<FolderLine> out;
    std::unordered_set<std::string> seen;
    size_t lineNumber = 1;
    size_t start = 0;
    while (start <= text.size()) {
        size_t end = text.find_first_of("\r\n", start);
        if (end == std::string_view::npos) end = text.size();
        const std::string_view line = trimmed(text.substr(start, end - start), " \t");
        if (!line.empty()) {
            FolderLine entry;
            entry.line = lineNumber;
            entry.text = std::string(line);
            // Root and duplicates by the lexical form, as the watch set
            // cleans its candidates (watchCandidates).
            const std::string clean = line[0] == '/' ? lexicalAbsolutePath(line) : std::string();
            if (line[0] != '/') {
                entry.problem = FolderLineProblem::NotAbsolute;
            } else if (clean == "/") {
                entry.problem = FolderLineProblem::Root;
            } else if (!seen.insert(clean).second) {
                entry.problem = FolderLineProblem::Duplicate;
            }
            out.push_back(std::move(entry));
        }
        if (end == text.size()) break;
        // "\r\n" is one line break.
        start = (text[end] == '\r' && end + 1 < text.size() && text[end + 1] == '\n') ? end + 2 : end + 1;
        lineNumber++;
    }
    return out;
}

const char *folderLineProblemText(FolderLineProblem problem) {
    switch (problem) {
        case FolderLineProblem::None: return "";
        case FolderLineProblem::NotAbsolute: return "not an absolute path (ignored)";
        case FolderLineProblem::Root: return "the root folder is never watched";
        case FolderLineProblem::Duplicate: return "listed twice";
    }
    return "";
}

WatchFolderList parseWatchFolders(std::string_view text) {
    WatchFolderList out;
    for (FolderLine &line : parseFolderLines(text)) {
        switch (line.problem) {
            case FolderLineProblem::None:
            case FolderLineProblem::Root:
                out.folders.push_back(std::move(line.text));
                break;
            case FolderLineProblem::NotAbsolute:
                out.ignored.push_back(std::move(line.text));
                break;
            case FolderLineProblem::Duplicate:
                break;
        }
    }
    return out;
}

ShareLinkList parseShareLinks(std::string_view text) {
    ShareLinkList out;
    for (FolderLine &line : parseFolderLines(text)) {
        switch (line.problem) {
            case FolderLineProblem::None:
                out.links.push_back(lexicalAbsolutePath(line.text));
                break;
            case FolderLineProblem::NotAbsolute:
                out.ignored.push_back(std::move(line.text));
                break;
            case FolderLineProblem::Root:
            case FolderLineProblem::Duplicate:
                break;
        }
    }
    return out;
}

// --- executables and folders ---

const char *pathCheckText(PathCheck check) {
    switch (check) {
        case PathCheck::Ok: return "ok";
        case PathCheck::Empty: return "not set";
        case PathCheck::NotAbsolute: return "not an absolute path";
        case PathCheck::Missing: return "not found";
        case PathCheck::NotFile: return "not a file";
        case PathCheck::NotDirectory: return "not a folder";
        case PathCheck::NotExecutable: return "not executable";
        case PathCheck::NotReadable: return "not readable";
    }
    return "unknown";
}

bool isExecutableFile(const std::string &path) {
    return checkExecutable(path) == PathCheck::Ok;
}

bool isReadableFile(const std::string &path) {
    return checkReadableFile(path) == PathCheck::Ok;
}

PathCheck checkExecutable(const std::string &path) {
    struct stat st;
    const PathCheck base = statPath(path, st);
    if (base != PathCheck::Ok) return base;
    if (!S_ISREG(st.st_mode)) return PathCheck::NotFile;
    if (access(path.c_str(), X_OK) != 0) return PathCheck::NotExecutable;
    return PathCheck::Ok;
}

PathCheck checkReadableFile(const std::string &path) {
    struct stat st;
    const PathCheck base = statPath(path, st);
    if (base != PathCheck::Ok) return base;
    if (!S_ISREG(st.st_mode)) return PathCheck::NotFile;
    if (access(path.c_str(), R_OK) != 0) return PathCheck::NotReadable;
    return PathCheck::Ok;
}

PathCheck checkDirectory(const std::string &path) {
    struct stat st;
    const PathCheck base = statPath(path, st);
    if (base != PathCheck::Ok) return base;
    if (!S_ISDIR(st.st_mode)) return PathCheck::NotDirectory;
    return PathCheck::Ok;
}

bool isScriptCliPath(std::string_view path) {
    static constexpr std::string_view kSuffix = ".ts";
    return path.size() >= kSuffix.size() && path.substr(path.size() - kSuffix.size()) == kSuffix;
}

PathCheck checkCliPath(const std::string &path) {
    return isScriptCliPath(path) ? checkReadableFile(path) : checkExecutable(path);
}

// --- bun ---

std::optional<std::string> environmentValue(const std::vector<std::string> &environment, std::string_view name) {
    for (const std::string &entry : environment) {
        if (entry.size() > name.size() && entry.compare(0, name.size(), name) == 0 && entry[name.size()] == '=') {
            return entry.substr(name.size() + 1);
        }
    }
    return std::nullopt;
}

std::vector<std::string> defaultBunSearchDirs(const std::vector<std::string> &environment) {
    std::vector<std::string> dirs;
    std::optional<std::string> home = environmentValue(environment, "HOME");
    if (home && !home->empty() && (*home)[0] == '/') {
        std::string h = *home;
        while (h.size() > 1 && h.back() == '/') h.pop_back();
        dirs.push_back((h == "/" ? std::string() : h) + "/.bun/bin");
    }
    dirs.push_back("/opt/homebrew/bin");
    dirs.push_back("/usr/local/bin");
    return dirs;
}

std::vector<std::string> bunCandidates(const std::vector<std::string> &searchDirs) {
    std::vector<std::string> out;
    std::unordered_set<std::string> seen;
    for (std::string dir : searchDirs) {
        if (dir.empty() || dir[0] != '/' || hasNul(dir)) continue;
        while (dir.size() > 1 && dir.back() == '/') dir.pop_back();
        std::string candidate = (dir == "/" ? std::string() : dir) + "/bun";
        if (seen.insert(candidate).second) out.push_back(std::move(candidate));
    }
    return out;
}

std::string findBun(const std::vector<std::string> &searchDirs) {
    for (const std::string &candidate : bunCandidates(searchDirs)) {
        if (isExecutableFile(candidate)) return candidate;
    }
    return std::string();
}

// --- library mapping ---

std::string normalizedPrefix(std::string_view value) {
    const std::string_view v = trimmed(value, " \t\r\n");
    if (v.empty() || v[0] != '/' || hasNul(v)) return std::string(v);
    return lexicalAbsolutePath(v);
}

PrefixPairCheck validatePrefixPair(std::string_view from, std::string_view to) {
    const std::string_view f = trimmed(from, " \t\r\n");
    const std::string_view t = trimmed(to, " \t\r\n");
    if (f.empty() && t.empty()) return PrefixPairCheck::BothEmpty;
    if (f.empty()) return PrefixPairCheck::FromMissing;
    if (t.empty()) return PrefixPairCheck::ToMissing;
    if (f[0] != '/' || hasNul(f)) return PrefixPairCheck::FromNotAbsolute;
    if (t[0] != '/' || hasNul(t)) return PrefixPairCheck::ToNotAbsolute;
    if (lexicalAbsolutePath(f) == "/") return PrefixPairCheck::FromRoot;
    if (lexicalAbsolutePath(t) == "/") return PrefixPairCheck::ToRoot;
    return PrefixPairCheck::Ok;
}

const char *prefixPairCheckText(PrefixPairCheck check) {
    switch (check) {
        case PrefixPairCheck::Ok: return "ok";
        case PrefixPairCheck::BothEmpty: return "no mapping";
        case PrefixPairCheck::FromMissing: return "the NAS path prefix is missing";
        case PrefixPairCheck::ToMissing: return "the Mac path prefix is missing";
        case PrefixPairCheck::FromNotAbsolute: return "the NAS path prefix must be an absolute path";
        case PrefixPairCheck::ToNotAbsolute: return "the Mac path prefix must be an absolute path";
        case PrefixPairCheck::FromRoot: return "the NAS path prefix cannot be the root folder";
        case PrefixPairCheck::ToRoot: return "the Mac path prefix cannot be the root folder";
    }
    return "unknown";
}

} // namespace intake
