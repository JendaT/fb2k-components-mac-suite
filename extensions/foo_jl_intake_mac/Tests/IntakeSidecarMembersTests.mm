//
//  IntakeSidecarMembersTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeSidecarMembers: sidecar parsing, the CLI's safe
//  relative path rule, round-trip economy (one listing per directory, a read
//  only where a named sidecar exists, no I/O for roots that render nothing),
//  retry-then-keep-previous, and the POSIX access against a temp directory.
//  Synthetic names only.
//
// TEST_DEPS: src/Core/IntakeEnvelope.mm src/Core/IntakePath.mm src/Core/IntakeLog.mm
// TEST_DEPS: src/Core/IntakeDecorationMap.mm src/Core/IntakeReviewRule.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeDecorationMap.h"
#include "../src/Core/IntakePath.h"
#include "../src/Core/IntakeSidecarMembers.h"
#include "../src/Core/IntakeStatusModel.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <deque>
#include <map>
#include <string>
#include <vector>

using namespace intake;

// A scripted SidecarFileAccess that counts every call.
class FakeAccess : public SidecarFileAccess {
public:
    std::map<std::string, std::vector<std::string>> dirs;      // listable directories
    std::map<std::string, std::deque<std::string>> reads;      // per path: successive answers
    std::map<std::string, int> listCalls, readCalls;
    static constexpr const char *kFail = "<read fails>";       // a read that fails

    bool listDirectory(const std::string &directory, std::vector<std::string> &names) override {
        listCalls[directory]++;
        auto it = dirs.find(directory);
        if (it == dirs.end()) return false;
        names = it->second;
        return true;
    }
    bool readFile(const std::string &path, std::string &contents) override {
        readCalls[path]++;
        auto it = reads.find(path);
        if (it == reads.end() || it->second.empty()) return false;
        std::string answer = it->second.front();
        if (it->second.size() > 1) it->second.pop_front();  // the last answer repeats
        if (answer == kFail) return false;
        contents = answer;
        return true;
    }
    int totalLists() const {
        int n = 0;
        for (const auto &kv : listCalls) n += kv.second;
        return n;
    }
    int totalReads() const {
        int n = 0;
        for (const auto &kv : readCalls) n += kv.second;
        return n;
    }
};

static std::string sidecarJson(const std::vector<std::string> &paths) {
    std::string files;
    for (const std::string &p : paths) {
        if (!files.empty()) files += ",";
        files += "{\"path\":\"" + p + "\",\"audio_hash\":\"pcmsha1:00\",\"tags\":{\"title\":\"Test\"}}";
    }
    return "{\"schema\":1,\"id\":\"itk_x\",\"virtual\":true,\"files\":[" + files + "],\"status\":\"new\"}\n";
}

static IntakeRecord record(const std::string &id, const std::string &rootPath, IntakeStatus status,
                           bool verified = false) {
    IntakeRecord r;
    r.id = id;
    r.rootPath = rootPath;
    normalizePath(rootPath, r.rootKey);
    r.status = status;
    r.hasPlaced = status == IntakeStatus::Placed;
    r.placedVerified = verified;
    return r;
}

static void testNamesAndPaths() {
    g_context = "names";
    CHECK(namedSidecarName("itk_0000000a") == ".intake.itk_0000000a.json", "named sidecar file name");

    g_context = "safe-paths";
    CHECK(isSafeRelativePath("01 - Test Track One.wav"), "a plain name");
    CHECK(isSafeRelativePath("CD1/01 - Test Track One.wav"), "a disc subdirectory");
    CHECK(isSafeRelativePath("..hidden/a.wav") && isSafeRelativePath("a/.b"), "dot-led names that are not . or ..");
    CHECK(!isSafeRelativePath(""), "empty");
    CHECK(!isSafeRelativePath("/abs/a.wav"), "absolute");
    CHECK(!isSafeRelativePath("a/../b.wav") && !isSafeRelativePath(".."), "a .. segment");
    CHECK(!isSafeRelativePath("./a.wav") && !isSafeRelativePath("."), "a . segment");
    CHECK(!isSafeRelativePath("a//b.wav") && !isSafeRelativePath("a/"), "an empty segment");
    CHECK(!isSafeRelativePath("a\\b.wav"), "a backslash");
    CHECK(!isSafeRelativePath(std::string_view("a\0b", 3)), "a NUL");
}

static void testParse() {
    g_context = "parse";
    std::vector<std::string> paths;
    CHECK(parseSidecarMemberPaths(sidecarJson({"a.wav", "CD2/b.wav"}), paths), "a valid sidecar parses");
    CHECK(paths.size() == 2 && paths[0] == "a.wav" && paths[1] == "CD2/b.wav", "paths in order");
    CHECK(parseSidecarMemberPaths("  \n" + sidecarJson({"a.wav"}) + "\n\n", paths) && paths.size() == 1,
          "surrounding whitespace is fine");
    CHECK(parseSidecarMemberPaths(R"({"files":[]})", paths) && paths.empty(), "files [] is an empty member list");
    CHECK(!parseSidecarMemberPaths(R"({"id":"itk_x"})", paths), "no files member");
    CHECK(!parseSidecarMemberPaths(R"({"files":{"path":"a.wav"}})", paths), "files is not an array");
    CHECK(!parseSidecarMemberPaths(R"({"files":[{"path":"a.wav"},{"name":"b.wav"}]})", paths) && paths.empty(),
          "one entry without a path fails the whole sidecar");
    CHECK(!parseSidecarMemberPaths(R"({"files":[{"path":"a.wav"},{"path":"../b.wav"}]})", paths),
          "one unsafe path fails the whole sidecar (CLI readSidecar)");
    CHECK(!parseSidecarMemberPaths(R"({"files":[{"path":"/abs.wav"}]})", paths), "an absolute path fails");
    std::string truncated = sidecarJson({"a.wav", "b.wav"});
    truncated.resize(truncated.size() / 2);
    CHECK(!parseSidecarMemberPaths(truncated, paths), "a half-written sidecar fails");
    CHECK(!parseSidecarMemberPaths("", paths) && !parseSidecarMemberPaths("[]", paths), "empty or an array fails");
    CHECK(parseSidecarMemberPaths(R"({"files":[{"path":"a.wav","tags":{"title":"bad \ud800 slice"}}]})", paths),
          "an unpaired surrogate escape elsewhere does not fail the sidecar");
    CHECK(parseSidecarMemberPaths("{\"files\":[{\"path\":\"Cafe\\u0301.wav\"}]}", paths) &&
              paths[0] == "Cafe\xCC\x81.wav",
          "an NFD path keeps its bytes");
}

static void testEconomy() {
    g_context = "economy";
    FakeAccess fs;
    const std::string album = "/income/dump/Fixture Artist - Test Album";
    const std::string singles = "/income/shop/Singles";
    const std::string tomb = "/income/dump/Fixture Artist - Collected Album";
    fs.dirs[album] = {".intake.json", "01.wav", "02.wav", "cover.jpg"};
    fs.dirs[singles] = {".intake.itk_00000011.json", ".intake.itk_00000012.json", ".intake.itk_00000013.json",
                        "Fixture Artist - One.wav", "Fixture Artist - Two.wav", "Fixture Artist - Three.wav",
                        "stray.wav"};
    fs.reads[singles + "/.intake.itk_00000011.json"] = {sidecarJson({"Fixture Artist - One.wav"})};
    fs.reads[singles + "/.intake.itk_00000012.json"] = {sidecarJson({"Fixture Artist - Two.wav"})};
    fs.reads[singles + "/.intake.itk_00000013.json"] = {sidecarJson({"Fixture Artist - Three.wav"})};
    std::vector<IntakeRecord> records = {
        record("itk_00000001", album, IntakeStatus::Resolved),
        record("itk_00000011", singles, IntakeStatus::New),
        record("itk_00000012", singles, IntakeStatus::Proposed),
        record("itk_00000013", singles, IntakeStatus::Rejected),
        record("itk_00000002", tomb, IntakeStatus::GcDone),
    };
    MemberLoadStats stats;
    MemberTable t = loadMembers(records, fs, nullptr, statusHasVisual, &stats);
    CHECK_EQ(t.size(), 5, "one entry per record");
    CHECK(t["itk_00000001"].kind == MemberKind::WholeDirectory && t["itk_00000001"].source == MemberSource::Listed,
          "no named sidecar: whole directory, verified by the listing");
    CHECK(t["itk_00000011"].kind == MemberKind::Members && t["itk_00000011"].relativePaths.size() == 1 &&
              t["itk_00000011"].relativePaths[0] == "Fixture Artist - One.wav",
          "single 1 owns its file");
    CHECK(t["itk_00000012"].relativePaths == std::vector<std::string>{"Fixture Artist - Two.wav"}, "single 2");
    CHECK(t["itk_00000013"].relativePaths == std::vector<std::string>{"Fixture Artist - Three.wav"}, "single 3");
    CHECK(fs.listCalls[singles] == 1, "three singles in one directory cost one listing");
    CHECK(fs.listCalls[album] == 1, "the album directory is listed once");
    CHECK(fs.listCalls.count(tomb) == 0, "a gc_done tombstone costs no I/O at all");
    CHECK_EQ(fs.totalReads(), 3, "only the three named sidecars are read; .intake.json never is");
    CHECK(t["itk_00000002"].kind == MemberKind::WholeDirectory && t["itk_00000002"].source == MemberSource::Assumed,
          "the skipped tombstone is assumed whole-directory");
    CHECK(stats.directories == 3 && stats.directoriesListed == 2 && stats.directoriesSkipped == 1,
          "stats: 3 directories, 2 listed, 1 skipped");
    CHECK(stats.sidecarReads == 3 && stats.sidecarRetries == 0 && stats.sidecarFailures == 0, "stats: reads");

    g_context = "economy-mixed";
    // A virtual root that renders nothing, next to one that does: one
    // listing, one read.
    FakeAccess mixed;
    mixed.dirs["/income/loose"] = {".intake.itk_00000021.json", ".intake.itk_00000022.json"};
    mixed.reads["/income/loose/.intake.itk_00000021.json"] = {sidecarJson({"a.wav"})};
    mixed.reads["/income/loose/.intake.itk_00000022.json"] = {sidecarJson({"b.wav"})};
    MemberTable m = loadMembers({record("itk_00000021", "/income/loose", IntakeStatus::New),
                                 record("itk_00000022", "/income/loose", IntakeStatus::GcDone)},
                                mixed, nullptr, statusHasVisual, &stats);
    CHECK(mixed.totalLists() == 1 && mixed.totalReads() == 1, "one listing, one read");
    CHECK(m["itk_00000022"].kind == MemberKind::None, "the undecorated virtual root matches nothing, unread");
    MemberTable shared = loadMembers({record("itk_00000031", "/income/old", IntakeStatus::GcDone),
                                      record("itk_00000032", "/income/old", IntakeStatus::GcDone)},
                                     mixed, nullptr, statusHasVisual, &stats);
    CHECK(shared["itk_00000031"].kind == MemberKind::None && shared["itk_00000032"].kind == MemberKind::None,
          "skipped roots sharing a directory are virtual: they match nothing");
    CHECK(mixed.listCalls.count("/income/old") == 0, "and cost no I/O");

    g_context = "economy-all";
    FakeAccess every;
    every.dirs[tomb] = {".intake.json"};
    loadMembers({record("itk_00000002", tomb, IntakeStatus::GcDone)}, every, nullptr, {}, &stats);
    CHECK(every.listCalls[tomb] == 1, "an empty predicate means every root gets I/O");
    FakeAccess unverified;
    loadMembers({record("itk_00000003", "/income/x", IntakeStatus::Placed, false),
                 record("itk_00000004", "/income/y", IntakeStatus::Placed, true)},
                unverified, nullptr, statusHasVisual, &stats);
    CHECK(unverified.listCalls.count("/income/x") == 0 && unverified.listCalls["/income/y"] == 1,
          "placed unverified is skipped, placed verified is listed");
}

static void testRetryAndPrevious() {
    g_context = "retry";
    const std::string dir = "/income/loose";
    const std::string path = dir + "/.intake.itk_00000041.json";
    std::string half = sidecarJson({"a.wav", "b.wav"});
    half.resize(half.size() / 2);
    std::vector<IntakeRecord> records = {record("itk_00000041", dir, IntakeStatus::Resolved)};

    FakeAccess once;
    once.dirs[dir] = {".intake.itk_00000041.json"};
    once.reads[path] = {half, sidecarJson({"a.wav", "b.wav"})};
    MemberLoadStats stats;
    MemberTable t = loadMembers(records, once, nullptr, statusHasVisual, &stats);
    CHECK(t["itk_00000041"].kind == MemberKind::Members && t["itk_00000041"].relativePaths.size() == 2,
          "a half-written sidecar is read again and the second read wins");
    CHECK(once.readCalls[path] == 2 && stats.sidecarRetries == 1 && stats.sidecarFailures == 0, "one retry");

    MemberTable previous;
    previous["itk_00000041"].kind = MemberKind::Members;
    previous["itk_00000041"].source = MemberSource::Listed;
    previous["itk_00000041"].relativePaths = {"old.wav"};

    FakeAccess twice;
    twice.dirs[dir] = {".intake.itk_00000041.json"};
    twice.reads[path] = {half};
    t = loadMembers(records, twice, &previous, statusHasVisual, &stats);
    CHECK(twice.readCalls[path] == 2, "retried exactly once");
    CHECK(t["itk_00000041"].kind == MemberKind::Members && t["itk_00000041"].source == MemberSource::Previous &&
              t["itk_00000041"].relativePaths == std::vector<std::string>{"old.wav"},
          "still unparseable: the previous member list is kept");
    CHECK(stats.sidecarFailures == 1 && stats.keptPrevious == 1, "stats: failure, kept previous");

    t = loadMembers(records, twice, nullptr, statusHasVisual, &stats);
    CHECK(t["itk_00000041"].kind == MemberKind::None, "no previous list: the root matches nothing");

    MemberTable wasWhole;
    wasWhole["itk_00000041"].kind = MemberKind::WholeDirectory;
    t = loadMembers(records, twice, &wasWhole, statusHasVisual, &stats);
    CHECK(t["itk_00000041"].kind == MemberKind::None,
          "a previous whole-directory class is not a member list: matches nothing");

    FakeAccess unreadable;
    unreadable.dirs[dir] = {".intake.itk_00000041.json"};
    unreadable.reads[path] = {FakeAccess::kFail};
    t = loadMembers(records, unreadable, &previous, statusHasVisual, &stats);
    CHECK(unreadable.readCalls[path] == 2 && t["itk_00000041"].source == MemberSource::Previous,
          "a failed read is retried and falls back like a parse failure");

    g_context = "list-failure";
    FakeAccess gone;  // nothing listable: unmounted share
    MemberTable prevWhole;
    prevWhole["itk_00000051"].kind = MemberKind::WholeDirectory;
    prevWhole["itk_00000051"].source = MemberSource::Listed;
    t = loadMembers({record("itk_00000051", "/income/a", IntakeStatus::New),
                     record("itk_00000052", "/income/b", IntakeStatus::New),
                     record("itk_00000053", "/income/c", IntakeStatus::New),
                     record("itk_00000054", "/income/c", IntakeStatus::Resolved),
                     record("itk_00000041", dir, IntakeStatus::Resolved)},
                    gone, &previous, statusHasVisual, &stats);
    CHECK(t["itk_00000041"].source == MemberSource::Previous && t["itk_00000041"].relativePaths.size() == 1,
          "an unlistable directory keeps the previous member list");
    t = loadMembers({record("itk_00000051", "/income/a", IntakeStatus::New),
                     record("itk_00000052", "/income/b", IntakeStatus::New),
                     record("itk_00000053", "/income/c", IntakeStatus::New),
                     record("itk_00000054", "/income/c", IntakeStatus::Resolved)},
                    gone, &prevWhole, statusHasVisual, &stats);
    CHECK(t["itk_00000051"].kind == MemberKind::WholeDirectory && t["itk_00000051"].source == MemberSource::Previous,
          "an unlistable directory keeps the previous whole-directory class");
    CHECK(t["itk_00000052"].kind == MemberKind::WholeDirectory && t["itk_00000052"].source == MemberSource::Assumed,
          "unlistable, no previous, alone in its directory: assumed whole-directory");
    CHECK(t["itk_00000053"].kind == MemberKind::None && t["itk_00000054"].kind == MemberKind::None,
          "unlistable, no previous, sharing a directory: matches nothing");
    CHECK(stats.listFailures == 3 && gone.totalReads() == 0, "three failed listings, no reads");
}

static void testSpellings() {
    g_context = "spellings";
    // The CLI reports an NFD root_path (SMB): I/O must use exactly those
    // bytes, and an NFC spelling of the same directory shares the listing.
    const std::string nfd = "/income/dump/Cafe\xCC\x81 Album";
    const std::string nfc = "/income/dump/Caf\xC3\xA9 Album";
    FakeAccess fs;
    fs.dirs[nfd] = {".intake.itk_00000061.json", ".intake.itk_00000062.json"};
    fs.reads[nfd + "/.intake.itk_00000061.json"] = {sidecarJson({"Cafe\\u0301 One.wav"})};
    fs.reads[nfd + "/.intake.itk_00000062.json"] = {sidecarJson({"Two.wav"})};
    MemberLoadStats stats;
    MemberTable t = loadMembers({record("itk_00000061", nfd, IntakeStatus::New),
                                 record("itk_00000062", nfc, IntakeStatus::New)},
                                fs, nullptr, statusHasVisual, &stats);
    CHECK(fs.listCalls[nfd] == 1 && fs.listCalls.count(nfc) == 0,
          "both spellings share one listing, through the first record's raw path");
    CHECK(t["itk_00000061"].kind == MemberKind::Members && t["itk_00000061"].relativePaths[0] == "Cafe\xCC\x81 One.wav",
          "the member path keeps the sidecar's NFD bytes");
    CHECK(t["itk_00000062"].kind == MemberKind::Members, "the NFC-spelled root found its sidecar");
    CHECK(stats.directories == 1, "one directory");
}

static void testPosix() {
    g_context = "posix";
    SidecarFileAccess &fs = posixSidecarFileAccess();
    std::string dir = mock::newDir("members");
    CHECK(!dir.empty(), "temp directory");
    std::string singles = dir + "/Singles";
    std::string album = dir + "/Fixture Artist - Test Album";
    mkdir(singles.c_str(), 0755);
    mkdir(album.c_str(), 0755);
    mock::writeFile(album + "/.intake.json", "{\"schema\":1}\n");
    mock::writeFile(album + "/01.wav", "");
    mock::writeFile(singles + "/.intake.itk_00000071.json", sidecarJson({"Fixture Artist - One.wav"}));
    mock::writeFile(singles + "/.intake.itk_00000072.json", sidecarJson({"Fixture Artist - Two.wav"}));
    mock::writeFile(singles + "/.intake.itk_00000073.json", sidecarJson({"Fixture Artist - Three.wav"}));
    mock::writeFile(singles + "/Fixture Artist - One.wav", "");

    std::vector<std::string> names;
    CHECK(fs.listDirectory(singles, names) && names.size() == 4, "listing returns the four entries");
    bool dots = false;
    for (const std::string &n : names) dots = dots || n == "." || n == "..";
    CHECK(!dots, "no . or .. entries");
    CHECK(!fs.listDirectory(dir + "/missing", names) && names.empty(), "a missing directory fails");
    std::string contents;
    CHECK(fs.readFile(album + "/.intake.json", contents) && contents == "{\"schema\":1}\n", "readFile");
    CHECK(!fs.readFile(album + "/missing.json", contents) && contents.empty(), "a missing file fails");

    MemberLoadStats stats;
    MemberTable t = loadMembers({record("itk_00000070", album, IntakeStatus::Resolved),
                                 record("itk_00000071", singles, IntakeStatus::New),
                                 record("itk_00000072", singles, IntakeStatus::Proposed),
                                 record("itk_00000073", singles, IntakeStatus::Approved)},
                                fs, nullptr, statusHasVisual, &stats);
    CHECK(t["itk_00000070"].kind == MemberKind::WholeDirectory, "posix: whole-directory album");
    CHECK(t["itk_00000071"].kind == MemberKind::Members && t["itk_00000072"].kind == MemberKind::Members &&
              t["itk_00000073"].kind == MemberKind::Members,
          "posix: three singles");
    CHECK(t["itk_00000073"].relativePaths == std::vector<std::string>{"Fixture Artist - Three.wav"},
          "posix: the third single's member");
    CHECK(stats.directoriesListed == 2 && stats.sidecarReads == 3, "posix: two listings, three reads");
}

int main(void) {
    atexit(mock::removeTempRoot);
    @autoreleasepool {
        testNamesAndPaths();
        testParse();
        testEconomy();
        testRetryAndPrevious();
        testSpellings();
        testPosix();
    }
    mock::removeTempRoot();
    TEST_MAIN_END();
}
