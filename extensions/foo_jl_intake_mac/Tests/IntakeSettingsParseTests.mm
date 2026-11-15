//
//  IntakeSettingsParseTests.mm
//  foo_jl_intake_mac
//
//  The preferences page's checks (PLAN.md B5): the folder list with line
//  numbers and problems (and parseWatchFolders built on it), the path
//  checks on real files in a temp directory, the bun search directories and
//  candidates, the environment lookup, and the library prefix pair.
//  Hermetic: every file lives in a fresh temp directory, removed at the end.
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeSettingsParse.h"
#include "TestHarness.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdlib>
#include <string>
#include <vector>

using namespace intake;

namespace {

std::string g_tempRoot;

std::string makeTempRoot() {
    const char *tmp = getenv("TMPDIR");
    std::string pattern = std::string(tmp && *tmp ? tmp : "/tmp/");
    if (pattern.back() != '/') pattern += '/';
    pattern += "intake-settings-XXXXXX";
    std::vector<char> buffer(pattern.begin(), pattern.end());
    buffer.push_back('\0');
    return mkdtemp(buffer.data()) ? std::string(buffer.data()) : std::string();
}

std::string makeDir(const std::string &name) {
    const std::string path = g_tempRoot + "/" + name;
    mkdir(path.c_str(), 0755);
    return path;
}

std::string makeFile(const std::string &path, mode_t mode) {
    const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        (void)write(fd, "#!/bin/sh\n", 10);
        close(fd);
    }
    chmod(path.c_str(), mode);
    return path;
}

void removeTree(const std::string &root) {
    if (root.empty()) return;
    // Restore permissions first so every file can be removed.
    NSString *path = [NSString stringWithUTF8String:root.c_str()];
    NSDirectoryEnumerator *walker = [[NSFileManager defaultManager] enumeratorAtPath:path];
    for (NSString *relative in walker) {
        chmod([path stringByAppendingPathComponent:relative].fileSystemRepresentation, 0755);
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

} // anonymous namespace

static void testTrimmed() {
    g_context = "trimmed";
    CHECK(trimmedSetting("  /a b/c \t\r\n") == "/a b/c", "outer whitespace only; inner spaces kept");
    CHECK(trimmedSetting(" \n\t").empty() && trimmedSetting("").empty(), "blank");
}

static void testFolderLines() {
    g_context = "folder-lines";
    const std::vector<FolderLine> lines =
        parseFolderLines("/fixture/a\r\n  /fixture/b \t\n\nrelative/c\r/fixture/a\n~/d\n/\n/./\n/fixture/e");
    CHECK_EQ(lines.size(), 8, "every non-blank line");
    if (lines.size() == 8) {
        CHECK(lines[0].line == 1 && lines[0].text == "/fixture/a" && lines[0].problem == FolderLineProblem::None,
              "line 1, ended by \\r\\n");
        CHECK(lines[1].line == 2 && lines[1].text == "/fixture/b" && lines[1].problem == FolderLineProblem::None,
              "line 2: trimmed of spaces and tabs");
        CHECK(lines[2].line == 4 && lines[2].problem == FolderLineProblem::NotAbsolute,
              "line 4 (line 3 blank): relative");
        CHECK(lines[3].line == 5 && lines[3].problem == FolderLineProblem::Duplicate,
              "line 5 (after a lone \\r): a duplicate");
        CHECK(lines[4].line == 6 && lines[4].text == "~/d" && lines[4].problem == FolderLineProblem::NotAbsolute,
              "~ is not expanded: not absolute");
        CHECK(lines[5].line == 7 && lines[5].problem == FolderLineProblem::Root, "/ is the root");
        CHECK(lines[6].line == 8 && lines[6].problem == FolderLineProblem::Root, "/./ is the root too");
        CHECK(lines[7].line == 9 && lines[7].problem == FolderLineProblem::None, "the last line, no newline");
    }
    CHECK(parseFolderLines("").empty() && parseFolderLines("\n \r\n\t").empty(), "blank text: no lines");
    CHECK(parseFolderLines("/x\n").size() == 1, "a trailing newline adds no line");
    CHECK(std::string(folderLineProblemText(FolderLineProblem::None)).empty() &&
              !std::string(folderLineProblemText(FolderLineProblem::NotAbsolute)).empty() &&
              !std::string(folderLineProblemText(FolderLineProblem::Root)).empty() &&
              !std::string(folderLineProblemText(FolderLineProblem::Duplicate)).empty(),
          "problem texts");
}

static void testWatchFolders() {
    g_context = "watch-folders";
    WatchFolderList l = parseWatchFolders("/fixture/a\n  /fixture/b  \r\n\n\trelative/c\r/fixture/a\n~/d\n/fixture/e");
    CHECK(l.folders.size() == 3 && l.folders[0] == "/fixture/a" && l.folders[1] == "/fixture/b" &&
              l.folders[2] == "/fixture/e",
          "absolute lines, in order, a duplicate once");
    CHECK(l.ignored.size() == 2 && l.ignored[0] == "relative/c" && l.ignored[1] == "~/d", "relative lines ignored");
    WatchFolderList root = parseWatchFolders("/\n/fixture/x");
    CHECK(root.folders.size() == 2 && root.folders[0] == "/" && root.ignored.empty(),
          "/ stays in the list (watchCandidates leaves it out), as before the refactor");
}

static void testPathChecks() {
    g_context = "path-checks";
    const std::string dir = makeDir("paths");
    const std::string exec = makeFile(dir + "/intake", 0755);
    const std::string plain = makeFile(dir + "/plain", 0644);
    const std::string script = makeFile(dir + "/cli.ts", 0644);
    const std::string locked = makeFile(dir + "/locked", 0000);
    const std::string link = dir + "/link-to-intake";
    symlink(exec.c_str(), link.c_str());

    CHECK(checkExecutable(exec) == PathCheck::Ok && isExecutableFile(exec), "an executable file");
    CHECK(checkExecutable(link) == PathCheck::Ok, "a symlink to one (followed)");
    CHECK(checkExecutable(plain) == PathCheck::NotExecutable && !isExecutableFile(plain), "no execute bit");
    CHECK(checkExecutable(dir) == PathCheck::NotFile && !isExecutableFile(dir), "a directory is not a file");
    CHECK(checkExecutable(dir + "/missing") == PathCheck::Missing, "missing");
    CHECK(checkExecutable("relative/intake") == PathCheck::NotAbsolute, "relative");
    CHECK(checkExecutable("") == PathCheck::Empty, "empty");
    CHECK(checkExecutable(std::string("/bin/sh\0x", 9)) == PathCheck::Missing, "a NUL byte is never statted");

    CHECK(checkReadableFile(plain) == PathCheck::Ok && isReadableFile(plain), "a readable file");
    if (geteuid() != 0) {
        CHECK(checkReadableFile(locked) == PathCheck::NotReadable && !isReadableFile(locked), "mode 000: unreadable");
    }
    CHECK(checkReadableFile(dir) == PathCheck::NotFile, "a directory is not a readable file");

    CHECK(checkDirectory(dir) == PathCheck::Ok, "a folder");
    CHECK(checkDirectory(plain) == PathCheck::NotDirectory, "a file is not a folder");
    CHECK(checkDirectory(dir + "/missing") == PathCheck::Missing && checkDirectory("") == PathCheck::Empty &&
              checkDirectory("rules") == PathCheck::NotAbsolute,
          "missing, empty, relative");

    CHECK(isScriptCliPath("/x/cli.ts") && isScriptCliPath(".ts") && !isScriptCliPath("/x/cli.tsx") &&
              !isScriptCliPath("/x/ts") && !isScriptCliPath(""),
          ".ts suffix only");
    CHECK(checkCliPath(script) == PathCheck::Ok, "a .ts CLI only needs to be readable");
    CHECK(checkCliPath(plain) == PathCheck::NotExecutable, "any other CLI must be executable");
    CHECK(checkCliPath(exec) == PathCheck::Ok, "an executable CLI");
    CHECK(checkCliPath(dir + "/missing.ts") == PathCheck::Missing, "a missing .ts");
    CHECK(std::string(pathCheckText(PathCheck::NotExecutable)) == "not executable" &&
              std::string(pathCheckText(PathCheck::Ok)) == "ok",
          "texts");
}

static void testBun() {
    g_context = "bun";
    std::vector<std::string> dirs = defaultBunSearchDirs({"PATH=/x", "HOME=/Users/fixture/"});
    CHECK(dirs.size() == 3 && dirs[0] == "/Users/fixture/.bun/bin" && dirs[1] == "/opt/homebrew/bin" &&
              dirs[2] == "/usr/local/bin",
          "~/.bun/bin from HOME (trailing slash dropped), then Homebrew, then /usr/local");
    CHECK(defaultBunSearchDirs({"HOME=relative"}).size() == 2 && defaultBunSearchDirs({}).size() == 2,
          "no usable HOME: two directories");

    const std::vector<std::string> candidates =
        bunCandidates({"/a/bin/", "relative", "", "/", "/a/bin", std::string("/n\0ul", 5), "/b//"});
    CHECK(candidates.size() == 3 && candidates[0] == "/a/bin/bun" && candidates[1] == "/bun" &&
              candidates[2] == "/b/bun",
          "absolute directories only, trailing slashes dropped, each once");

    const std::string none = makeDir("bun-none");
    const std::string notExec = makeDir("bun-plain");
    const std::string good = makeDir("bun-good");
    makeFile(notExec + "/bun", 0644);
    makeFile(good + "/bun", 0755);
    CHECK(findBun({none, notExec, good}) == good + "/bun", "the first executable candidate");
    CHECK(findBun({none, notExec}).empty() && findBun({}).empty(), "none: empty");

    CHECK(environmentValue({"PATHX=/no", "PATH=/a:/b", "PATH=/second"}, "PATH") == std::optional<std::string>("/a:/b"),
          "the first exact NAME= entry");
    CHECK(!environmentValue({"PATH"}, "PATH") && !environmentValue({}, "HOME"), "absent");
    CHECK(environmentValue({"EMPTY="}, "EMPTY") == std::optional<std::string>(""), "an empty value is present");
}

static void testPrefixPair() {
    g_context = "prefix-pair";
    CHECK(validatePrefixPair("/share/library", "/Volumes/library") == PrefixPairCheck::Ok, "both absolute");
    CHECK(validatePrefixPair("", "") == PrefixPairCheck::BothEmpty && validatePrefixPair("  ", "\t") == PrefixPairCheck::BothEmpty,
          "both empty (whitespace counts as empty)");
    CHECK(validatePrefixPair("", "/Volumes/library") == PrefixPairCheck::FromMissing, "only the Mac prefix");
    CHECK(validatePrefixPair("/share/library", " ") == PrefixPairCheck::ToMissing, "only the NAS prefix");
    CHECK(validatePrefixPair("share/library", "/Volumes/library") == PrefixPairCheck::FromNotAbsolute,
          "a relative NAS prefix");
    CHECK(validatePrefixPair("/share/library", "~/library") == PrefixPairCheck::ToNotAbsolute, "a relative Mac prefix");
    CHECK(validatePrefixPair(" /share/library ", " /Volumes/library\n") == PrefixPairCheck::Ok, "trimmed first");
    CHECK(prefixPairValid(PrefixPairCheck::Ok) && prefixPairValid(PrefixPairCheck::BothEmpty) &&
              !prefixPairValid(PrefixPairCheck::FromMissing) && !prefixPairValid(PrefixPairCheck::ToNotAbsolute),
          "valid settings: a full pair or none");
    CHECK(std::string(prefixPairCheckText(PrefixPairCheck::ToMissing)).find("Mac path prefix") != std::string::npos,
          "texts name the field");

    // B5 review: the root maps every path; the check is lexical.
    CHECK(validatePrefixPair("/", "/fixture/mac") == PrefixPairCheck::FromRoot &&
              validatePrefixPair("/fixture/..", "/fixture/mac") == PrefixPairCheck::FromRoot &&
              validatePrefixPair("/fixture/nas", "//") == PrefixPairCheck::ToRoot &&
              validatePrefixPair("/fixture/nas", "/fixture/./..") == PrefixPairCheck::ToRoot,
          "the root folder, however spelled, is not usable on either side");
    CHECK(!prefixPairValid(PrefixPairCheck::FromRoot) && !prefixPairValid(PrefixPairCheck::ToRoot),
          "and not a valid setting");
    CHECK(std::string(prefixPairCheckText(PrefixPairCheck::FromRoot)).find("root folder") != std::string::npos,
          "the root text");
    CHECK(validatePrefixPair("/fixture/nas/", "/fixture/mac/") == PrefixPairCheck::Ok, "trailing slashes are fine");
}

static void testNormalizedPrefix() {
    g_context = "normalized-prefix";
    CHECK(normalizedPrefix(" /fixture/nas/ ") == "/fixture/nas", "trimmed, no trailing slash");
    CHECK(normalizedPrefix("/fixture//nas/./x/..") == "/fixture/nas", "lexically clean");
    CHECK(normalizedPrefix("/") == "/" && normalizedPrefix("//") == "/", "the root stays the root");
    CHECK(normalizedPrefix(" relative/x/ ") == "relative/x/" && normalizedPrefix("\t").empty(),
          "not absolute: trimmed only, as typed");
    CHECK(normalizedPrefix(std::string("/a\0/b/", 6)) == std::string("/a\0/b/", 6), "a NUL byte: left alone");
}

static void testLexicalFolderLines() {
    g_context = "folder-lines-lexical";
    // B5 review: the page flags what the watch set will skip or merge
    // (watchCandidates cleans every line with lexicalAbsolutePath).
    const std::vector<FolderLine> lines =
        parseFolderLines("/fixture/..\n/fixture/a/../..\n/fixture/a\n/fixture/a/\n/fixture/./a\n/fixture/b/../a2");
    CHECK_EQ(lines.size(), 6, "six lines");
    if (lines.size() == 6) {
        CHECK(lines[0].problem == FolderLineProblem::Root && lines[1].problem == FolderLineProblem::Root,
              "\"..\" back to / is the root");
        CHECK(lines[2].problem == FolderLineProblem::None, "the first spelling");
        CHECK(lines[3].problem == FolderLineProblem::Duplicate && lines[4].problem == FolderLineProblem::Duplicate,
              "a trailing slash or \".\" names the same folder");
        CHECK(lines[5].problem == FolderLineProblem::None, "another folder");
    }
    WatchFolderList l = parseWatchFolders("/fixture/a\n/fixture/a/\n/fixture/..");
    CHECK(l.folders.size() == 2 && l.folders[0] == "/fixture/a" && l.folders[1] == "/fixture/..",
          "a lexical duplicate is dropped; a root line is kept (watchCandidates skips it)");
}

int main(void) {
    @autoreleasepool {
        g_tempRoot = makeTempRoot();
        if (g_tempRoot.empty()) {
            printf("FAIL: no temp directory\n");
            return 1;
        }
        testTrimmed();
        testFolderLines();
        testWatchFolders();
        testPathChecks();
        testBun();
        testPrefixPair();
        testNormalizedPrefix();
        testLexicalFolderLines();
        removeTree(g_tempRoot);
    }
    TEST_MAIN_END();
}
