//
//  IntakeSettingsParse.h
//  foo_jl_intake
//
//  The checks behind the preferences page (PLAN.md B5, 3.9), shared with
//  the code that uses the same settings, so each rule has one
//  implementation:
//
//   - Folder lists (watch_folders, share_links): one absolute path per
//     line. parseFolderLines reports every non-blank line with its line
//     number and what is wrong with it, for the page's inline flags;
//     parseWatchFolders (IntakeConfig, IntakeWatchSet) keeps the usable
//     folders, parseShareLinks (IntakeConfig, B11) the usable links.
//   - Executables and folders: the CLI path, the bun path and the rules
//     folder. IntakeCommandArgs uses isExecutableFile, isReadableFile and
//     the bun search below when it builds a call.
//   - bun: the search directories and the candidates in them, in the order
//     IntakeCommandArgs probes them (PLAN.md 3.4).
//   - The library mapping (swap_prefix_from / swap_prefix_to, decision 2):
//     one prefix pair, both absolute (neither "/") or both empty, stored
//     lexically clean (normalizedPrefix). Swap and the library index (B9)
//     use it (IntakeSwapPlanner makeLibraryPrefix).
//   - Confirmations (confirm_reject B6, confirm_gc B9): ints, 0 off,
//     anything else on, default on (confirmSetting).
//   - auto_scan (B12): an int read the same way, 0 off, anything else on,
//     default on (autoScanSetting).
//
//  Thread-safety: reentrant. The path checks and findBun read the
//  filesystem (stat, access), so never call them on the decorate path or,
//  for a path that may lie on a network share, on the main thread.
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace intake {

// `text` without surrounding spaces, tabs, CR and LF.
std::string trimmedSetting(std::string_view text);

// `path` with "//" collapsed, "." segments dropped, ".." popping a segment
// (staying at "/"), and a trailing '/' removed (except for "/"). Bytes are
// otherwise kept (no NFC). Empty when `path` is empty or not absolute. No
// filesystem access. The watch set (IntakeWatchSet) cleans every candidate
// with it; the folder list and prefix checks below use the same rule.
std::string lexicalAbsolutePath(std::string_view path);

// --- folder lists ---

enum class FolderLineProblem {
    None,
    NotAbsolute, // does not start with '/' ("~/x" included): ignored
    Root,        // lexically "/" ("/.", "//", "/a/..", ...): kept, but never watched (IntakeWatchSet)
    Duplicate,   // lexically the same folder as an earlier line ("/a", "/a/"): ignored
};

struct FolderLine {
    size_t line = 0;   // 1-based; "\r\n", "\n" and a lone "\r" each end one line
    std::string text;  // trimmed of spaces and tabs
    FolderLineProblem problem = FolderLineProblem::None;
};

// Every non-blank line of `text`, in order.
std::vector<FolderLine> parseFolderLines(std::string_view text);

// "not an absolute path", ... ; empty for None.
const char *folderLineProblemText(FolderLineProblem problem);

struct WatchFolderList {
    std::vector<std::string> folders;  // absolute, trimmed, in order, each once
    std::vector<std::string> ignored;  // non-empty lines that are not absolute paths
};

// The watch_folders setting, from parseFolderLines: lines with no problem or
// Root go to `folders` (watchCandidates leaves "/" out), NotAbsolute lines
// to `ignored`, duplicates are dropped.
WatchFolderList parseWatchFolders(std::string_view text);

struct ShareLinkList {
    std::vector<std::string> links;    // absolute, lexically clean, in order, each once
    std::vector<std::string> ignored;  // non-empty lines that are not absolute paths
};

// The share_links setting (B11), from parseFolderLines: lines with no
// problem go to `links` through lexicalAbsolutePath (no trailing '/', the
// spelling foobar2000's file://<link>/<rel> items use), NotAbsolute lines
// to `ignored`; Root lines (every path would lie under "/") and duplicates
// are dropped.
ShareLinkList parseShareLinks(std::string_view text);

// --- executables and folders ---

enum class PathCheck {
    Ok,
    Empty,
    NotAbsolute,
    Missing,       // does not exist, cannot be examined, or holds a NUL byte
    NotFile,       // exists but is not a regular file
    NotDirectory,  // exists but is not a directory
    NotExecutable, // a regular file without execute permission for this process
    NotReadable,   // a regular file this process cannot read
};

// "not found", "not executable", ... ; "ok" for Ok.
const char *pathCheckText(PathCheck check);

// stat() says a regular file (symlinks followed) and access(X_OK) passes.
bool isExecutableFile(const std::string &path);
// stat() says a regular file and access(R_OK) passes.
bool isReadableFile(const std::string &path);

PathCheck checkExecutable(const std::string &path);
PathCheck checkReadableFile(const std::string &path);
PathCheck checkDirectory(const std::string &path);

// A CLI path ending in ".ts" runs as `<bun> <path>` (PLAN.md 3.4).
bool isScriptCliPath(std::string_view path);
// The CLI path: a .ts script must be a readable file, anything else an
// executable one.
PathCheck checkCliPath(const std::string &path);

// --- bun ---

// The value of NAME in a "NAME=value" list (the first match, like getenv),
// or nullopt.
std::optional<std::string> environmentValue(const std::vector<std::string> &environment, std::string_view name);

// ~/.bun/bin (from HOME in `environment`, "NAME=value" each; skipped when
// HOME is unset or not absolute), /opt/homebrew/bin, /usr/local/bin.
std::vector<std::string> defaultBunSearchDirs(const std::vector<std::string> &environment);

// "<dir>/bun" for every directory that is absolute and holds no NUL byte,
// trailing slashes dropped ("/bun" for "/"), each once, in order. No
// filesystem access.
std::vector<std::string> bunCandidates(const std::vector<std::string> &searchDirs);

// The first candidate that is an executable file, or "".
std::string findBun(const std::vector<std::string> &searchDirs);

// --- library mapping ---

enum class PrefixPairCheck {
    Ok,              // both set, both absolute, neither the root folder
    BothEmpty,       // no mapping (the default)
    FromMissing,     // only the Mac prefix is set
    ToMissing,       // only the NAS prefix is set
    FromNotAbsolute,
    ToNotAbsolute,
    FromRoot,        // lexically "/": it would map every path
    ToRoot,
};

// A prefix as stored and used: trimmed and, when absolute (no NUL byte),
// lexically cleaned (lexicalAbsolutePath: no trailing '/', "." and ".."
// resolved). Anything else is returned trimmed, as typed.
std::string normalizedPrefix(std::string_view value);

// Both values are trimmed first (whitespace only counts as empty); the
// root check is lexical.
PrefixPairCheck validatePrefixPair(std::string_view from, std::string_view to);
// Ok and BothEmpty are valid settings; only Ok maps anything.
inline bool prefixPairValid(PrefixPairCheck check) {
    return check == PrefixPairCheck::Ok || check == PrefixPairCheck::BothEmpty;
}
const char *prefixPairCheckText(PrefixPairCheck check);

// --- confirmations ---

// The default of confirm_reject and confirm_gc: on.
inline constexpr int64_t kConfirmSettingDefault = 1;

// A stored confirmation switch: 0 is off, any other value on (a missing key
// reads as kConfirmSettingDefault).
inline bool confirmSetting(int64_t stored) {
    return stored != 0;
}

// --- auto-scan (B12) ---

// The default of auto_scan ("Scan income folders automatically"): on.
inline constexpr int64_t kAutoScanSettingDefault = 1;

// The stored auto_scan switch: 0 is off, any other value on (a missing key
// reads as kAutoScanSettingDefault).
inline bool autoScanSetting(int64_t stored) {
    return stored != 0;
}

} // namespace intake
