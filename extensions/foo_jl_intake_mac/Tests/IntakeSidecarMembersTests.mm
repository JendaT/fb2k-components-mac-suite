//
//  IntakeSidecarMembersTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeSidecarMembers: sidecar parsing, the CLI's safe
//  relative path rule, round-trip economy (one listing per shared directory,
//  none for a lone root, a read only where a named sidecar exists, no I/O for
//  roots that render nothing), retry-then-keep-previous, stopping early
//  (cancel, deadline, an unreachable share), and the POSIX access against a
//  temp directory. Synthetic names only.
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

#include <atomic>
#include <cerrno>
#include <chrono>
#include <deque>
#include <functional>
#include <map>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

using namespace intake;

// A scripted SidecarFileAccess that counts every call.
class FakeAccess : public SidecarFileAccess {
public:
    std::map<std::string, std::vector<std::string>> dirs;      // listable directories
    std::map<std::string, std::deque<std::string>> reads;      // per path: successive answers
    std::map<std::string, int> listErrors, readErrors;         // errno of a failure (default ENOENT)
    std::map<std::string, int> listCalls, readCalls;
    std::function<void(const std::string &)> onList;           // runs inside each listing
    static constexpr const char *kFail = "<read fails>";       // a read that fails

    bool listDirectory(const std::string &directory, std::vector<std::string> &names, int &error) override {
        listCalls[directory]++;
        if (onList) onList(directory);
        error = 0;
        auto it = dirs.find(directory);
        if (it == dirs.end()) {
            auto e = listErrors.find(directory);
            error = e == listErrors.end() ? ENOENT : e->second;
            return false;
        }
        names = it->second;
        return true;
    }
    bool readFile(const std::string &path, std::string &contents, int &error) override {
        readCalls[path]++;
        error = 0;
        auto e = readErrors.find(path);
        auto it = reads.find(path);
        if (e != readErrors.end() || it == reads.end() || it->second.empty()) {
            error = e == readErrors.end() ? ENOENT : e->second;
            return false;
        }
        std::string answer = it->second.front();
        if (it->second.size() > 1) it->second.pop_front();  // the last answer repeats
        if (answer == kFail) {
            error = EINVAL;
            return false;
        }
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
    CHECK(t["itk_00000001"].kind == MemberKind::WholeDirectory && t["itk_00000001"].source == MemberSource::Assumed,
          "a lone root: whole directory, assumed without a listing");
    CHECK(t["itk_00000011"].kind == MemberKind::Members && t["itk_00000011"].relativePaths.size() == 1 &&
              t["itk_00000011"].relativePaths[0] == "Fixture Artist - One.wav",
          "single 1 owns its file");
    CHECK(t["itk_00000012"].relativePaths == std::vector<std::string>{"Fixture Artist - Two.wav"}, "single 2");
    CHECK(t["itk_00000013"].relativePaths == std::vector<std::string>{"Fixture Artist - Three.wav"}, "single 3");
    CHECK(fs.listCalls[singles] == 1, "three singles in one directory cost one listing");
    CHECK(fs.listCalls.count(album) == 0, "the lone album root's directory is never listed");
    CHECK(fs.listCalls.count(tomb) == 0, "a gc_done tombstone costs no I/O at all");
    CHECK_EQ(fs.totalReads(), 3, "only the three named sidecars are read; .intake.json never is");
    CHECK(t["itk_00000002"].kind == MemberKind::WholeDirectory && t["itk_00000002"].source == MemberSource::Assumed,
          "the skipped tombstone is assumed whole-directory");
    CHECK(stats.directories == 3 && stats.directoriesListed == 1 && stats.directoriesSkipped == 1 &&
              stats.directoriesAssumed == 1,
          "stats: 3 directories, 1 listed, 1 skipped, 1 assumed");
    CHECK(stats.stop == MemberLoadStop::None && stats.directoriesNotTried == 0, "stats: ran to the end");
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
    every.dirs[tomb] = {".intake.itk_00000002.json", ".intake.itk_00000003.json"};
    every.reads[tomb + "/.intake.itk_00000002.json"] = {sidecarJson({"a.wav"})};
    every.reads[tomb + "/.intake.itk_00000003.json"] = {sidecarJson({"b.wav"})};
    loadMembers({record("itk_00000002", tomb, IntakeStatus::GcDone), record("itk_00000003", tomb, IntakeStatus::GcDone)},
                every, nullptr, {}, &stats);
    CHECK(every.listCalls[tomb] == 1 && every.totalReads() == 2, "an empty predicate means every root gets I/O");
    FakeAccess unverified;
    loadMembers({record("itk_00000003", "/income/x", IntakeStatus::Placed, false),
                 record("itk_00000005", "/income/x", IntakeStatus::GcDone),
                 record("itk_00000004", "/income/y", IntakeStatus::Placed, true),
                 record("itk_00000006", "/income/y", IntakeStatus::New)},
                unverified, nullptr, statusHasVisual, &stats);
    CHECK(unverified.listCalls.count("/income/x") == 0 && unverified.listCalls["/income/y"] == 1,
          "placed unverified is skipped, placed verified is listed");

    g_context = "economy-lone";
    // A lone root is listed only when the last load found a member list.
    FakeAccess lone;
    lone.dirs["/income/one"] = {".intake.itk_00000007.json"};
    lone.reads["/income/one/.intake.itk_00000007.json"] = {sidecarJson({"a.wav"})};
    std::vector<IntakeRecord> one = {record("itk_00000007", "/income/one", IntakeStatus::New)};
    MemberTable first = loadMembers(one, lone, nullptr, statusHasVisual, &stats);
    CHECK(lone.totalLists() == 0 && first["itk_00000007"].kind == MemberKind::WholeDirectory &&
              first["itk_00000007"].source == MemberSource::Assumed && stats.directoriesAssumed == 1,
          "no previous entry: assumed whole-directory, no I/O");
    MemberTable again = loadMembers(one, lone, &first, statusHasVisual, &stats);
    CHECK(lone.totalLists() == 0 && again["itk_00000007"].kind == MemberKind::WholeDirectory,
          "a previous whole-directory class: still no I/O");
    MemberTable wasMembers;
    wasMembers["itk_00000007"].kind = MemberKind::Members;
    wasMembers["itk_00000007"].relativePaths = {"old.wav"};
    MemberTable listed = loadMembers(one, lone, &wasMembers, statusHasVisual, &stats);
    CHECK(lone.listCalls["/income/one"] == 1 && listed["itk_00000007"].kind == MemberKind::Members &&
              listed["itk_00000007"].relativePaths == std::vector<std::string>{"a.wav"},
          "a previous member list (the folder's siblings went): listed and read again");
}

static void testRetryAndPrevious() {
    g_context = "retry";
    const std::string dir = "/income/loose";
    const std::string path = dir + "/.intake.itk_00000041.json";
    std::string half = sidecarJson({"a.wav", "b.wav"});
    half.resize(half.size() / 2);
    // A sibling that renders nothing keeps the directory shared (listed).
    std::vector<IntakeRecord> records = {record("itk_00000041", dir, IntakeStatus::Resolved),
                                         record("itk_00000042", dir, IntakeStatus::GcDone)};

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
    FakeAccess gone;  // nothing listable: unmounted share (ENOENT)
    MemberTable prevWhole;
    prevWhole["itk_00000051"].kind = MemberKind::WholeDirectory;
    prevWhole["itk_00000051"].source = MemberSource::Listed;
    t = loadMembers({record("itk_00000051", "/income/a", IntakeStatus::New),
                     record("itk_00000052", "/income/b", IntakeStatus::New),
                     record("itk_00000053", "/income/c", IntakeStatus::New),
                     record("itk_00000054", "/income/c", IntakeStatus::Resolved),
                     record("itk_00000041", dir, IntakeStatus::Resolved)},
                    gone, &previous, statusHasVisual, &stats);
    CHECK(gone.listCalls[dir] == 1 && t["itk_00000041"].source == MemberSource::Previous &&
              t["itk_00000041"].relativePaths.size() == 1,
          "a lone root with a previous member list is listed; unlistable, it keeps that list");
    t = loadMembers({record("itk_00000051", "/income/a", IntakeStatus::New),
                     record("itk_00000055", "/income/a", IntakeStatus::GcDone),
                     record("itk_00000052", "/income/b", IntakeStatus::New),
                     record("itk_00000053", "/income/c", IntakeStatus::New),
                     record("itk_00000054", "/income/c", IntakeStatus::Resolved)},
                    gone, &prevWhole, statusHasVisual, &stats);
    CHECK(t["itk_00000051"].kind == MemberKind::WholeDirectory && t["itk_00000051"].source == MemberSource::Previous,
          "an unlistable directory keeps the previous whole-directory class");
    CHECK(t["itk_00000055"].kind == MemberKind::None, "its sibling without a previous class matches nothing");
    CHECK(t["itk_00000052"].kind == MemberKind::WholeDirectory && t["itk_00000052"].source == MemberSource::Assumed &&
              gone.listCalls.count("/income/b") == 0,
          "a lone root without a previous member list: assumed whole-directory, never listed");
    CHECK(t["itk_00000053"].kind == MemberKind::None && t["itk_00000054"].kind == MemberKind::None,
          "unlistable, no previous, sharing a directory: matches nothing");
    CHECK(stats.listFailures == 2 && gone.totalReads() == 0, "two failed listings, no reads");
    CHECK(stats.stop == MemberLoadStop::None, "ENOENT is one missing folder, not a dead share: no stop");
}

static void testStop() {
    g_context = "stop-share";
    // A listing that times out (stalled share): no further I/O at all.
    const std::string a = "/income/a", b = "/income/b", c = "/income/c";
    std::vector<IntakeRecord> records = {
        record("itk_00000081", a, IntakeStatus::New),    record("itk_00000082", a, IntakeStatus::New),
        record("itk_00000083", b, IntakeStatus::New),    record("itk_00000084", b, IntakeStatus::Resolved),
        record("itk_00000085", c, IntakeStatus::New),    record("itk_00000086", c, IntakeStatus::Resolved),
        record("itk_00000087", "/income/lone", IntakeStatus::New)};
    MemberTable previous;
    previous["itk_00000083"].kind = MemberKind::Members;
    previous["itk_00000083"].relativePaths = {"old.wav"};
    previous["itk_00000084"].kind = MemberKind::WholeDirectory;
    FakeAccess stalled;
    stalled.listErrors[a] = ETIMEDOUT;
    stalled.dirs[b] = {".intake.itk_00000083.json"};
    stalled.dirs[c] = {".intake.itk_00000085.json"};
    MemberLoadStats stats;
    MemberTable t = loadMembers(records, stalled, &previous, statusHasVisual, &stats);
    CHECK(stalled.listCalls[a] == 1 && stalled.listCalls.count(b) == 0 && stalled.listCalls.count(c) == 0 &&
              stalled.totalReads() == 0,
          "after an ETIMEDOUT listing nothing else is tried");
    CHECK(stats.stop == MemberLoadStop::ShareUnreachable && stats.stopError == ETIMEDOUT &&
              stats.directoriesNotTried == 2 && stats.listFailures == 1,
          "stats: stopped on an unreachable share, two directories not tried");
    CHECK(t["itk_00000083"].kind == MemberKind::Members && t["itk_00000083"].source == MemberSource::Previous &&
              t["itk_00000084"].kind == MemberKind::WholeDirectory && t["itk_00000084"].source == MemberSource::Previous,
          "untried roots keep their previous classification");
    CHECK(t["itk_00000085"].kind == MemberKind::None && t["itk_00000081"].kind == MemberKind::None,
          "untried or unlisted shared roots without a previous class match nothing");
    CHECK(t["itk_00000087"].kind == MemberKind::WholeDirectory, "a lone root needs no I/O and is still answered");
    CHECK_EQ(t.size(), records.size(), "every record still gets an entry");

    int unreachable = 0;
    for (int e : {ETIMEDOUT, ENOTCONN, EIO, EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH, ECONNRESET, ECONNABORTED,
                  ESTALE}) {
        if (isShareUnreachableError(e)) unreachable++;
    }
    CHECK(unreachable == 10 && !isShareUnreachableError(ENOENT) && !isShareUnreachableError(EACCES) &&
              !isShareUnreachableError(0),
          "share errors stop the load; a missing or forbidden folder does not");

    g_context = "stop-read";
    // A sidecar read that times out: no retry, no other read, no listing.
    FakeAccess slowRead;
    slowRead.dirs[b] = {".intake.itk_00000083.json", ".intake.itk_00000084.json"};
    slowRead.readErrors[b + "/.intake.itk_00000083.json"] = ENOTCONN;
    slowRead.reads[b + "/.intake.itk_00000084.json"] = {sidecarJson({"b.wav"})};
    slowRead.dirs[c] = {};
    t = loadMembers({records[2], records[3], records[4], records[5]}, slowRead, &previous, statusHasVisual, &stats);
    CHECK(slowRead.readCalls[b + "/.intake.itk_00000083.json"] == 1 && slowRead.readCalls.count(b + "/.intake.itk_00000084.json") == 0 &&
              slowRead.listCalls.count(c) == 0,
          "after an ENOTCONN read: no retry, no further read or listing");
    CHECK(stats.stop == MemberLoadStop::ShareUnreachable && stats.sidecarRetries == 0 && stats.sidecarFailures == 0,
          "a read given up on a dead share is a stop, not a sidecar failure");
    CHECK(t["itk_00000083"].source == MemberSource::Previous && t["itk_00000083"].relativePaths.size() == 1,
          "the unread root keeps its previous member list");
    CHECK(t["itk_00000084"].kind == MemberKind::None,
          "a virtual root not read, with only a previous whole-directory class, matches nothing");

    g_context = "stop-cancel";
    std::atomic<bool> cancel{true};
    MemberLoadLimits limits;
    limits.cancel = &cancel;
    FakeAccess untouched;
    untouched.dirs[a] = {};
    t = loadMembers(records, untouched, &previous, statusHasVisual, &stats, limits);
    CHECK(untouched.totalLists() == 0 && untouched.totalReads() == 0 && stats.stop == MemberLoadStop::Cancelled &&
              stats.directoriesNotTried == 3,
          "cancelled before the start: no I/O at all");
    CHECK(t["itk_00000083"].source == MemberSource::Previous && t.size() == records.size(),
          "and every root is still answered");

    // Cancelled while the first listing is in flight: that listing finishes,
    // nothing after it starts (not even the reads it made worth doing).
    cancel = false;
    FakeAccess midway;
    midway.dirs[a] = {".intake.itk_00000081.json", ".intake.itk_00000082.json"};
    midway.reads[a + "/.intake.itk_00000081.json"] = {sidecarJson({"a1.wav"})};
    midway.dirs[b] = {};
    midway.onList = [&cancel](const std::string &) { cancel = true; };
    t = loadMembers(records, midway, &previous, statusHasVisual, &stats, limits);
    CHECK(midway.totalLists() == 1 && midway.totalReads() == 0 && stats.stop == MemberLoadStop::Cancelled,
          "cancelled mid-load: the call in flight ends, nothing else starts");
    CHECK(t["itk_00000081"].kind == MemberKind::None && t["itk_00000083"].source == MemberSource::Previous,
          "unread virtual roots match nothing; untried ones keep their previous class");

    g_context = "stop-deadline";
    MemberLoadLimits past;
    past.deadline = std::chrono::steady_clock::now() - std::chrono::milliseconds(1);
    FakeAccess late;
    late.dirs[a] = {};
    loadMembers(records, late, nullptr, statusHasVisual, &stats, past);
    CHECK(late.totalLists() == 0 && stats.stop == MemberLoadStop::Deadline, "a deadline already passed: no I/O");

    // A listing that blocks past the deadline: the next one never starts.
    MemberLoadLimits soon;
    soon.deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
    FakeAccess blocking;
    blocking.dirs[a] = {};
    blocking.dirs[b] = {};
    blocking.dirs[c] = {};
    blocking.onList = [](const std::string &) { std::this_thread::sleep_for(std::chrono::milliseconds(250)); };
    loadMembers(records, blocking, nullptr, statusHasVisual, &stats, soon);
    CHECK(blocking.totalLists() == 1 && stats.stop == MemberLoadStop::Deadline && stats.directoriesNotTried == 2,
          "a slow listing past the deadline: the rest are not tried");
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
    int posixError = 0;
    CHECK(fs.listDirectory(singles, names, posixError) && names.size() == 4, "listing returns the four entries");
    bool dots = false;
    for (const std::string &n : names) dots = dots || n == "." || n == "..";
    CHECK(!dots, "no . or .. entries");
    CHECK(!fs.listDirectory(dir + "/missing", names, posixError) && names.empty(), "a missing directory fails");
    std::string contents;
    CHECK(fs.readFile(album + "/.intake.json", contents, posixError) && contents == "{\"schema\":1}\n", "readFile");
    CHECK(!fs.readFile(album + "/missing.json", contents, posixError) && contents.empty(), "a missing file fails");

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
    CHECK(stats.directoriesListed == 1 && stats.directoriesAssumed == 1 && stats.sidecarReads == 3,
          "posix: one listing (the lone album is assumed), three reads");
    int error = 0;
    CHECK(!fs.listDirectory(dir + "/missing", names, error) && error == ENOENT, "posix: a failed listing's errno");
    CHECK(!fs.readFile(dir + "/missing.json", contents, error) && error == ENOENT, "posix: a failed read's errno");
}

static std::unordered_map<std::string, std::string> keysOf(const std::vector<IntakeRecord> &records) {
    std::unordered_map<std::string, std::string> out;
    for (const IntakeRecord &r : records) out[r.id] = r.rootKey;
    return out;
}

static void testIncremental() {
    g_context = "incremental";
    const std::string loose = "/income/shop/Loose Tracks";
    const std::string singles = "/income/dump/Singles";
    const std::string one = "/income/one";
    FakeAccess fs;
    fs.dirs[loose] = {".intake.itk_00000016.json", ".intake.itk_00000017.json", "a.wav", "b.wav"};
    fs.dirs[singles] = {".intake.itk_00000021.json", ".intake.itk_00000022.json", "c.wav", "d.wav"};
    fs.dirs[one] = {".intake.itk_00000007.json", "e.wav"};
    fs.reads[loose + "/.intake.itk_00000016.json"] = {sidecarJson({"a.wav"})};
    fs.reads[loose + "/.intake.itk_00000017.json"] = {sidecarJson({"b.wav"})};
    fs.reads[singles + "/.intake.itk_00000021.json"] = {sidecarJson({"c.wav"})};
    fs.reads[singles + "/.intake.itk_00000022.json"] = {sidecarJson({"d.wav"})};
    fs.reads[one + "/.intake.itk_00000007.json"] = {sidecarJson({"e.wav"})};
    std::vector<IntakeRecord> records = {
        record("itk_00000016", loose, IntakeStatus::New),
        record("itk_00000017", loose, IntakeStatus::Proposed),
        record("itk_00000021", singles, IntakeStatus::Resolved),
        record("itk_00000022", singles, IntakeStatus::Approved),
        record("itk_00000007", one, IntakeStatus::New),
    };
    MemberTable lonePrevious;  // the lone root's folder had siblings last time
    lonePrevious["itk_00000007"].kind = MemberKind::Members;
    lonePrevious["itk_00000007"].source = MemberSource::Listed;
    lonePrevious["itk_00000007"].relativePaths = {"e.wav"};
    MemberLoadStats stats;
    MemberTable full = loadMembers(records, fs, &lonePrevious, statusHasVisual, &stats);
    CHECK(fs.listCalls[loose] == 1 && fs.listCalls[singles] == 1 && fs.listCalls[one] == 1 && fs.totalReads() == 5,
          "the first (full) load lists every shared folder and the lone root with a member list");
    const auto previousKeys = keysOf(records);

    // One sidecar changed in Loose Tracks.
    MemberReuse reuse;
    reuse.enabled = true;
    reuse.changedKeys = {records[0].rootKey};
    reuse.previousKeys = &previousKeys;
    MemberTable inc = loadMembers(records, fs, &full, statusHasVisual, &stats, MemberLoadLimits(), reuse);
    CHECK(fs.listCalls[loose] == 2, "the changed folder is listed again");
    CHECK(fs.listCalls[singles] == 1 && fs.listCalls[one] == 1, "unchanged folders are not listed");
    CHECK_EQ(fs.totalReads(), 7, "only the changed folder's two sidecars are read again");
    CHECK(stats.directoriesReused == 2 && stats.directoriesListed == 1, "stats: 2 reused, 1 listed");
    CHECK(inc["itk_00000021"].source == MemberSource::Reused && inc["itk_00000022"].source == MemberSource::Reused &&
              inc["itk_00000007"].source == MemberSource::Reused,
          "reused roots are marked Reused");
    CHECK(inc["itk_00000021"].kind == MemberKind::Members &&
              inc["itk_00000021"].relativePaths == std::vector<std::string>{"c.wav"} &&
              inc["itk_00000007"].relativePaths == std::vector<std::string>{"e.wav"},
          "with the previous member lists");
    CHECK(inc["itk_00000016"].source == MemberSource::Listed, "the changed folder's roots are freshly listed");

    g_context = "incremental-again";
    reuse.changedKeys.clear();
    MemberTable twice = loadMembers(records, fs, &inc, statusHasVisual, &stats, MemberLoadLimits(), reuse);
    CHECK(fs.totalLists() == 4 && stats.directoriesReused == 3, "a Reused classification is reused again");
    CHECK(twice["itk_00000016"].relativePaths == std::vector<std::string>{"a.wav"}, "unchanged content");

    g_context = "incremental-case";
    reuse.changedKeys = {"/INCOME/DUMP/SINGLES"};
    loadMembers(records, fs, &inc, statusHasVisual, &stats, MemberLoadLimits(), reuse);
    CHECK(fs.listCalls[singles] == 2, "a changed key differing in ASCII case still re-lists (a doubt costs a listing)");

    g_context = "incremental-new-root";
    std::vector<IntakeRecord> grown = records;
    grown.push_back(record("itk_00000023", singles, IntakeStatus::New));
    fs.dirs[singles].push_back(".intake.itk_00000023.json");
    fs.reads[singles + "/.intake.itk_00000023.json"] = {sidecarJson({"f.wav"})};
    reuse.changedKeys.clear();
    MemberTable withNew = loadMembers(grown, fs, &inc, statusHasVisual, &stats, MemberLoadLimits(), reuse);
    CHECK(fs.listCalls[singles] == 3 && withNew["itk_00000023"].relativePaths == std::vector<std::string>{"f.wav"},
          "a folder with a root the previous load did not have is listed");

    g_context = "incremental-moved";
    auto moved = previousKeys;
    moved["itk_00000021"] = "/income/dump/Elsewhere";
    reuse.previousKeys = &moved;
    loadMembers(records, fs, &inc, statusHasVisual, &stats, MemberLoadLimits(), reuse);
    CHECK(fs.listCalls[singles] == 4, "a root whose key changed since the previous load is listed");
    reuse.previousKeys = &previousKeys;

    g_context = "incremental-unverified";
    MemberTable failed = inc;
    failed["itk_00000021"].source = MemberSource::Previous;  // its last listing failed
    loadMembers(records, fs, &failed, statusHasVisual, &stats, MemberLoadLimits(), reuse);
    CHECK(fs.listCalls[singles] == 5, "a folder kept from a failed listing is listed again");
    MemberTable assumed = inc;
    assumed["itk_00000022"].source = MemberSource::Assumed;
    loadMembers(records, fs, &assumed, statusHasVisual, &stats, MemberLoadLimits(), reuse);
    CHECK(fs.listCalls[singles] == 6, "a folder that was only assumed is listed");
    MemberTable skipped = inc;
    skipped["itk_00000022"].kind = MemberKind::None;  // not read last time (it rendered nothing)
    loadMembers(records, fs, &skipped, statusHasVisual, &stats, MemberLoadLimits(), reuse);
    CHECK(fs.listCalls[singles] == 7, "a root whose member list was skipped but now renders is read");

    g_context = "incremental-off";
    MemberReuse noPrevious = reuse;
    loadMembers(records, fs, nullptr, statusHasVisual, &stats, MemberLoadLimits(), noPrevious);
    CHECK(stats.directoriesReused == 0 && fs.listCalls[singles] == 8, "no previous table: nothing reused");
    MemberReuse off;
    loadMembers(records, fs, &inc, statusHasVisual, &stats, MemberLoadLimits(), off);
    CHECK(stats.directoriesReused == 0 && stats.directoriesListed == 3, "reuse off: a full listing");
}

int main(void) {
    atexit(mock::removeTempRoot);
    @autoreleasepool {
        testNamesAndPaths();
        testParse();
        testEconomy();
        testRetryAndPrevious();
        testStop();
        testSpellings();
        testPosix();
        testIncremental();
    }
    mock::removeTempRoot();
    TEST_MAIN_END();
}
