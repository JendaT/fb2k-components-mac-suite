//
//  IntakeSnapshotTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeSnapshot (member map first, then the ancestor walk),
//  and the whole B2 pipeline over the mock CLI: version gate, status rows,
//  member load against the mock's tree in a temp directory, snapshot,
//  lookups of the tree's real file paths. Also prints the time of 5,000
//  lookups over 2,000 roots (printed, not asserted). Synthetic names only.
//
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeLog.mm src/Core/IntakeEnvelope.mm
// TEST_DEPS: src/Core/IntakeStatusModel.mm src/Core/IntakeSidecarMembers.mm
// TEST_DEPS: src/Core/IntakeDecorationMap.mm src/Core/IntakeReviewRule.mm
// TEST_DEPS: src/Core/IntakeVersionGate.mm src/Core/IntakeCapabilities.mm
// TEST_DEPS: src/Core/IntakeCommandArgs.mm src/Core/IntakeSemver.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeEnvelope.h"
#include "../src/Core/IntakePath.h"
#include "../src/Core/IntakeSnapshot.h"
#include "../src/Core/IntakeVersionGate.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <atomic>
#include <chrono>
#include <map>
#include <string>
#include <thread>
#include <vector>

using namespace intake;

static IntakeRecord record(const std::string &id, const std::string &rootPath,
                           IntakeStatus status = IntakeStatus::Resolved) {
    IntakeRecord r;
    r.id = id;
    r.rootPath = rootPath;
    normalizePath(rootPath, r.rootKey);
    r.status = status;
    return r;
}

static RootMembers members(std::vector<std::string> paths) {
    RootMembers m;
    m.kind = MemberKind::Members;
    m.source = MemberSource::Listed;
    m.relativePaths = std::move(paths);
    return m;
}

static RootMembers whole() {
    RootMembers m;
    m.kind = MemberKind::WholeDirectory;
    m.source = MemberSource::Listed;
    return m;
}

static std::string idAt(const IntakeSnapshot &s, const std::string &path) {
    const IntakeRecord *r = s.lookup(path);
    return r ? r->id : std::string("-");
}

static void testEmpty() {
    g_context = "empty";
    auto e = IntakeSnapshot::empty();
    CHECK(e && e->isEmpty() && e->size() == 0, "the empty snapshot has no records");
    CHECK(e->lookup("/income/a/b.wav") == nullptr, "and matches nothing");
    CHECK(e == IntakeSnapshot::empty(), "one shared empty instance");
    auto built = IntakeSnapshot::build({}, {});
    CHECK(built->isEmpty() && built->lookup("/x") == nullptr, "a snapshot built from nothing");
}

static void testWholeDirectory() {
    g_context = "whole-dir";
    auto s = IntakeSnapshot::build({record("itk_00000001", "/income/dump/Fixture Artist - Album")},
                                   {{"itk_00000001", whole()}});
    CHECK(idAt(*s, "/income/dump/Fixture Artist - Album/01.wav") == "itk_00000001", "a file in the root");
    CHECK(idAt(*s, "/income/dump/Fixture Artist - Album/CD2/01.wav") == "itk_00000001", "a file in a subdirectory");
    CHECK(idAt(*s, "/income/dump/Fixture Artist - Album") == "itk_00000001", "the root itself");
    CHECK(idAt(*s, "/income/dump/Fixture Artist - Album2/01.wav") == "-", "a name-prefix sibling does not match");
    CHECK(idAt(*s, "/income/dump/01.wav") == "-", "the parent does not match");
    CHECK(idAt(*s, "file:///income/dump/Fixture Artist - Album/01.wav") == "itk_00000001", "a file:// query");
    CHECK(idAt(*s, "mac-volume://0A1B/income/dump/Fixture Artist - Album/01.wav") == "-",
          "another scheme matches nothing (Integration converts it first)");
    CHECK(idAt(*s, "income/dump/Fixture Artist - Album/01.wav") == "-", "a relative query matches nothing");
    CHECK(idAt(*s, "/income/dump/fixture artist - album/01.wav") == "-", "matching is case-sensitive");
    CHECK(idAt(*s, "") == "-", "an empty query matches nothing");
    auto noEntry = IntakeSnapshot::build({record("itk_00000001", "/income/dump/A")}, {});
    CHECK(idAt(*noEntry, "/income/dump/A/01.wav") == "itk_00000001",
          "a record without a member entry counts as whole-directory");
}

static void testSingles() {
    g_context = "singles";
    // A directory holding 3 singles (virtual roots, one named sidecar each)
    // and a file no sidecar lists.
    const std::string dir = "/income/shop/Singles";
    std::vector<IntakeRecord> recs = {record("itk_00000011", dir, IntakeStatus::New),
                                      record("itk_00000012", dir, IntakeStatus::Proposed),
                                      record("itk_00000013", dir, IntakeStatus::Rejected)};
    MemberTable table = {{"itk_00000011", members({"Fixture Artist - One.wav"})},
                         {"itk_00000012", members({"Fixture Artist - Two.wav"})},
                         {"itk_00000013", members({"Fixture Artist - Three.wav"})}};
    auto s = IntakeSnapshot::build(recs, table);
    CHECK(idAt(*s, dir + "/Fixture Artist - One.wav") == "itk_00000011", "single 1");
    CHECK(idAt(*s, dir + "/Fixture Artist - Two.wav") == "itk_00000012", "single 2");
    CHECK(idAt(*s, dir + "/Fixture Artist - Three.wav") == "itk_00000013", "single 3");
    CHECK(idAt(*s, dir + "/stray.wav") == "-", "a file no sidecar lists matches nothing");
    CHECK(idAt(*s, dir) == "-", "the directory of singles itself matches nothing");
    CHECK(s->memberKeyCount() == 3 && s->directoryKeyCount() == 0, "three member keys, no directory key");
    const IntakeRecord *two = s->lookup(dir + "/Fixture Artist - Two.wav");
    CHECK(two && two->visual.icon == IntakeIcon::CircleLeftHalf, "each single carries its own visual");
    const IntakeRecord *three = s->lookup(dir + "/Fixture Artist - Three.wav");
    CHECK(three && three->visual.strikethrough, "the rejected single is struck");

    // Inside a whole-directory ancestor, the stray file falls back to it.
    recs.push_back(record("itk_00000010", "/income/shop", IntakeStatus::Resolved));
    table["itk_00000010"] = whole();
    auto nested = IntakeSnapshot::build(recs, table);
    CHECK(idAt(*nested, dir + "/stray.wav") == "itk_00000010", "with an ancestor root, the stray file falls back");
    CHECK(idAt(*nested, dir + "/Fixture Artist - One.wav") == "itk_00000011", "members still win over the ancestor");

    // Members in disc subdirectories.
    auto discs = IntakeSnapshot::build({record("itk_00000014", "/income/loose")},
                                       {{"itk_00000014", members({"CD1/01.wav", "CD2/01.wav"})}});
    CHECK(idAt(*discs, "/income/loose/CD2/01.wav") == "itk_00000014", "a member below a subdirectory");
    CHECK(idAt(*discs, "/income/loose/CD2/02.wav") == "-", "its unlisted neighbour");
}

static void testNested() {
    g_context = "nested";
    std::vector<IntakeRecord> recs = {record("itk_00000021", "/income/box"),
                                      record("itk_00000022", "/income/box/disc2"),
                                      record("itk_00000023", "/income/box/disc2/extras/deep")};
    auto s = IntakeSnapshot::build(recs, {});
    CHECK(idAt(*s, "/income/box/disc2/01.wav") == "itk_00000022", "the nested root wins over its parent");
    CHECK(idAt(*s, "/income/box/disc1/01.wav") == "itk_00000021", "a sibling falls back to the parent");
    CHECK(idAt(*s, "/income/box/disc2/extras/01.wav") == "itk_00000022", "a gap falls back to the nearest root");
    CHECK(idAt(*s, "/income/box/disc2/extras/deep/a/b.wav") == "itk_00000023", "the deepest of three");
    std::vector<IntakeRecord> reversed(recs.rbegin(), recs.rend());
    auto r = IntakeSnapshot::build(reversed, {});
    CHECK(idAt(*r, "/income/box/disc2/01.wav") == "itk_00000022", "independent of row order");

    // A whole-directory root and virtual roots sharing one directory.
    auto mixed = IntakeSnapshot::build({record("itk_00000031", "/income/mixed"), record("itk_00000032", "/income/mixed")},
                                       {{"itk_00000031", whole()}, {"itk_00000032", members({"virtual.wav"})}});
    CHECK(idAt(*mixed, "/income/mixed/virtual.wav") == "itk_00000032", "a member beats the whole-directory root");
    CHECK(idAt(*mixed, "/income/mixed/other.wav") == "itk_00000031", "other files go to the whole-directory root");
    // A virtual root inside a whole-directory root's subtree.
    auto inner = IntakeSnapshot::build({record("itk_00000041", "/income/box"),
                                        record("itk_00000042", "/income/box/singles")},
                                       {{"itk_00000041", whole()}, {"itk_00000042", members({"one.wav"})}});
    CHECK(idAt(*inner, "/income/box/singles/one.wav") == "itk_00000042", "a nested single");
    CHECK(idAt(*inner, "/income/box/singles/two.wav") == "itk_00000041", "a nested stray goes to the outer root");
}

static void testUnicode() {
    g_context = "unicode";
    const std::string nfc = "/income/Caf\xC3\xA9 Album";
    const std::string nfd = "/income/Cafe\xCC\x81 Album";
    auto nfdRoot = IntakeSnapshot::build({record("itk_00000051", nfd)}, {});
    CHECK(idAt(*nfdRoot, nfc + "/01.wav") == "itk_00000051", "NFD root, NFC query");
    CHECK(idAt(*nfdRoot, nfd + "/01.wav") == "itk_00000051", "NFD root, NFD query");
    const IntakeRecord *io = nfdRoot->lookup(nfc + "/01.wav");
    CHECK(io && io->rootPath == nfd, "the match hands back the CLI's NFD bytes for I/O");
    auto nfcRoot = IntakeSnapshot::build({record("itk_00000052", nfc)}, {});
    CHECK(idAt(*nfcRoot, nfd + "/01.wav") == "itk_00000052", "NFC root, NFD query");
    CHECK(idAt(*nfcRoot, "/income/Cafe Album/01.wav") == "-", "the unaccented spelling is another folder");

    // Member paths: NFD in the sidecar, either spelling in the query.
    auto members1 = IntakeSnapshot::build({record("itk_00000053", nfd)},
                                          {{"itk_00000053", members({"Cre\xCC\x80me.wav"})}});
    CHECK(idAt(*members1, nfc + "/Cr\xC3\xA8me.wav") == "itk_00000053", "NFD member, NFC query");
    CHECK(idAt(*members1, nfd + "/Cre\xCC\x80me.wav") == "itk_00000053", "NFD member, NFD query");
    auto members2 = IntakeSnapshot::build({record("itk_00000054", nfc)},
                                          {{"itk_00000054", members({"Cr\xC3\xA8me.wav"})}});
    CHECK(idAt(*members2, nfd + "/Cre\xCC\x80me.wav") == "itk_00000054", "NFC member, NFD query");
}

static void testTiesAndKinds() {
    g_context = "ties";
    auto dirTie = IntakeSnapshot::build({record("itk_000000b2", "/income/x"), record("itk_000000a1", "/income/x/")},
                                        {});
    CHECK(idAt(*dirTie, "/income/x/01.wav") == "itk_000000a1", "two whole-directory roots on one key: lowest id");
    auto dirTie2 = IntakeSnapshot::build({record("itk_000000a1", "/income/x/"), record("itk_000000b2", "/income/x")},
                                         {});
    CHECK(idAt(*dirTie2, "/income/x/01.wav") == "itk_000000a1", "independent of row order");
    auto memberTie = IntakeSnapshot::build(
        {record("itk_000000c3", "/income/y"), record("itk_000000c1", "/income/y")},
        {{"itk_000000c3", members({"a.wav"})}, {"itk_000000c1", members({"a.wav", "b.wav"})}});
    CHECK(idAt(*memberTie, "/income/y/a.wav") == "itk_000000c1", "two roots listing one file: lowest id");
    CHECK(idAt(*memberTie, "/income/y/b.wav") == "itk_000000c1", "the other member");

    g_context = "kinds";
    RootMembers none;
    none.kind = MemberKind::None;
    auto s = IntakeSnapshot::build({record("itk_00000061", "/income/z")}, {{"itk_00000061", none}});
    CHECK(idAt(*s, "/income/z/a.wav") == "-", "a None root matches nothing");
    CHECK(s->recordForId("itk_00000061") != nullptr, "but is still found by id");
    CHECK(s->recordForId("itk_99999999") == nullptr, "an unknown id");
    CHECK(s->members().count("itk_00000061") == 1, "members() hands the table on for the next load");
}

static void testKeysAndVisuals() {
    g_context = "alias-key";
    // B3 rewrites rootKey to a share-relative key; members follow it.
    IntakeRecord aliased = record("itk_00000071", "/Volumes/fixture-share-1/income/Fixture Artist - Album");
    aliased.rootKey = "/smbfs:fixture-share/income/Fixture Artist - Album";
    IntakeRecord single = record("itk_00000072", "/Volumes/fixture-share-1/income/Singles");
    single.rootKey = "/smbfs:fixture-share/income/Singles";
    auto s = IntakeSnapshot::build({aliased, single}, {{"itk_00000072", members({"one.wav"})}});
    const IntakeRecord *hit = s->lookupKey("/smbfs:fixture-share/income/Fixture Artist - Album/01.wav");
    CHECK(hit && hit->id == "itk_00000071", "an alias-key query finds the aliased root");
    CHECK(hit && hit->rootPath == "/Volumes/fixture-share-1/income/Fixture Artist - Album",
          "the aliased root keeps its mount-point I/O path");
    CHECK(s->lookupKey("/smbfs:fixture-share/income/Singles/one.wav") != nullptr, "members follow the rewritten key");
    CHECK(s->lookup("/Volumes/fixture-share-1/income/Singles/one.wav") == nullptr,
          "matching uses the key, not the I/O path");
    // An alias of an NFD root_path that Integration did not normalize: the
    // directory key is normalized at build, like the member keys.
    IntakeRecord nfdAlias = record("itk_00000073", "/Volumes/fixture-share-1/income/Cafe\xCC\x81 Album");
    nfdAlias.rootKey = "/smbfs:fixture-share/income/Cafe\xCC\x81 Album";
    IntakeRecord nfdSingle = record("itk_00000074", "/Volumes/fixture-share-1/income/Cre\xCC\x80me Singles");
    nfdSingle.rootKey = "/smbfs:fixture-share/income/Cre\xCC\x80me Singles";
    auto nfdKeys = IntakeSnapshot::build({nfdAlias, nfdSingle}, {{"itk_00000074", members({"one.wav"})}});
    const IntakeRecord *nfcHit = nfdKeys->lookupKey("/smbfs:fixture-share/income/Caf\xC3\xA9 Album/01.wav");
    CHECK(nfcHit && nfcHit->id == "itk_00000073", "an NFC query finds a whole-directory root under an NFD alias key");
    CHECK(nfdKeys->lookup("/smbfs:fixture-share/income/Cafe\xCC\x81 Album/01.wav") != nullptr,
          "and so does the NFD spelling");
    const IntakeRecord *nfcMember = nfdKeys->lookupKey("/smbfs:fixture-share/income/Cr\xC3\xA8me Singles/one.wav");
    CHECK(nfcMember && nfcMember->id == "itk_00000074", "members under an NFD alias key, as before");

    g_context = "visuals";
    IntakePalette custom;
    custom.tintNew = 0x10203040;
    IntakeRecord needs = record("itk_00000081", "/income/r", IntakeStatus::Resolved);
    needs.needsReview = true;
    auto v = IntakeSnapshot::build({record("itk_00000080", "/income/n", IntakeStatus::New), needs,
                                    record("itk_00000082", "/income/g", IntakeStatus::GcDone)},
                                   {}, custom);
    const IntakeRecord *n = v->recordForId("itk_00000080");
    CHECK(n && n->visual.bgTint == 0x10203040, "visuals use the palette passed in");
    const IntakeRecord *amber = v->recordForId("itk_00000081");
    CHECK(amber && amber->visual.icon == IntakeIcon::Warning, "the review rule applies at build");
    CHECK(v->lookup("/income/g/01.wav") && v->lookup("/income/g/01.wav")->visual.isNone(),
          "a gc_done root still matches (shadowing ancestors) but renders nothing");
}

static void testConcurrentReaders() {
    g_context = "concurrent";
    std::vector<IntakeRecord> recs;
    MemberTable table;
    for (int i = 0; i < 200; i++) {
        char id[16];
        snprintf(id, sizeof id, "itk_%08x", i);
        recs.push_back(record(id, "/income/c/Album " + std::to_string(i)));
        if (i % 2) table[id] = members({"01.wav"});
    }
    std::shared_ptr<const IntakeSnapshot> s = IntakeSnapshot::build(recs, table);
    std::atomic<int> wrong{0};
    std::vector<std::thread> threads;
    for (int t = 0; t < 4; t++) {
        threads.emplace_back([s, &wrong, t] {
            for (int k = 0; k < 2000; k++) {
                const int i = (k * 7 + t) % 200;
                const IntakeRecord *r = s->lookup("/income/c/Album " + std::to_string(i) + "/01.wav");
                char id[16];
                snprintf(id, sizeof id, "itk_%08x", i);
                if (!r || r->id != id) wrong++;
            }
        });
    }
    for (std::thread &t : threads) t.join();
    CHECK_EQ(wrong.load(), 0, "four threads reading one snapshot all get the right roots");
}

static void testTiming() {
    g_context = "timing";
    // 2,000 roots: 1,500 whole-directory albums and 500 singles in 100
    // directories of 5.
    std::vector<IntakeRecord> recs;
    MemberTable table;
    char id[16];
    for (int i = 0; i < 1500; i++) {
        snprintf(id, sizeof id, "itk_%08x", i);
        recs.push_back(record(id, "/Volumes/fixture-share/income/dump/Fixture Artist " + std::to_string(i % 300) +
                                      "/Fixture Artist - Test Album " + std::to_string(i)));
        table[id] = whole();
    }
    for (int i = 0; i < 500; i++) {
        snprintf(id, sizeof id, "itk_%08x", 1500 + i);
        recs.push_back(record(id, "/Volumes/fixture-share/income/shop/Singles " + std::to_string(i / 5)));
        table[id] = members({"Fixture Artist - Single " + std::to_string(i) + ".flac"});
    }
    auto start = std::chrono::steady_clock::now();
    auto s = IntakeSnapshot::build(recs, table);
    const double buildMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();

    // 5,000 queries: album tracks (some in disc folders), singles, strays
    // in singles folders, files outside every root, and NFD spellings.
    std::vector<std::string> queries;
    std::vector<std::string> expected;
    for (int q = 0; q < 5000; q++) {
        const int kind = q % 5;
        if (kind == 0 || kind == 1) {
            const int i = (q * 13) % 1500;
            snprintf(id, sizeof id, "itk_%08x", i);
            queries.push_back("/Volumes/fixture-share/income/dump/Fixture Artist " + std::to_string(i % 300) +
                              "/Fixture Artist - Test Album " + std::to_string(i) +
                              (kind == 1 ? "/CD2/07 - Test Track.flac" : "/01 - Test Track.flac"));
            expected.push_back(id);
        } else if (kind == 2) {
            const int i = (q * 7) % 500;
            snprintf(id, sizeof id, "itk_%08x", 1500 + i);
            queries.push_back("/Volumes/fixture-share/income/shop/Singles " + std::to_string(i / 5) +
                              "/Fixture Artist - Single " + std::to_string(i) + ".flac");
            expected.push_back(id);
        } else if (kind == 3) {
            queries.push_back("/Volumes/fixture-share/income/shop/Singles " + std::to_string(q % 100) + "/stray.flac");
            expected.push_back("-");
        } else {
            queries.push_back("/Volumes/fixture-share/library/Cafe\xCC\x81/Fixture Artist/" + std::to_string(q) +
                              ".flac");
            expected.push_back("-");
        }
    }
    int correct = 0;
    start = std::chrono::steady_clock::now();
    for (size_t q = 0; q < queries.size(); q++) {
        const IntakeRecord *r = s->lookup(queries[q]);
        if ((r ? r->id : std::string("-")) == expected[q]) correct++;
    }
    const double lookupMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    CHECK_EQ(correct, 5000, "every one of the 5,000 lookups is right");
    CHECK(s->size() == 2000 && s->memberKeyCount() == 500 && s->directoryKeyCount() == 1500, "2,000 roots indexed");
    printf("  timing: 5000 lookups over 2000 roots: %.2f ms total, %.2f us per lookup; build %.2f ms "
           "(ASan+UBSan -O1 test build)\n",
           lookupMs, lookupMs * 1000.0 / 5000.0, buildMs);
}

// Counts the I/O the pipeline does (the interface offers no stat at all).
class CountingAccess : public SidecarFileAccess {
public:
    explicit CountingAccess(SidecarFileAccess &inner) : inner_(inner) {}
    int lists = 0, reads = 0;
    std::string garbleSuffix;  // reads of a path ending in this return garbage
    bool listDirectory(const std::string &directory, std::vector<std::string> &names, int &error) override {
        lists++;
        return inner_.listDirectory(directory, names, error);
    }
    bool readFile(const std::string &path, std::string &contents, int &error) override {
        reads++;
        error = 0;
        if (!garbleSuffix.empty() && path.size() >= garbleSuffix.size() &&
            path.compare(path.size() - garbleSuffix.size(), garbleSuffix.size(), garbleSuffix) == 0) {
            contents = "{\"files\":[{\"pa";
            return true;
        }
        return inner_.readFile(path, contents, error);
    }

private:
    SidecarFileAccess &inner_;
};

struct Pipeline {
    bool ok = false;
    std::string root;   // $STATE/root
    std::string state;
    VersionGateResult gate;
    StatusParseResult status;
};

static Pipeline mockPipeline(const std::string &scenario) {
    Pipeline p;
    p.state = mock::setupState(scenario);
    if (p.state.empty()) return p;
    p.root = p.state + "/root";
    std::string out;
    int exitCode = mock::runCapture({mock::mockPath(), "version", "--json"}, mock::mockEnv(p.state), out);
    EnvelopeResult version = parseEnvelope(out, exitCode);
    if (version.outcome != CliOutcome::Ok) return p;
    p.gate = checkVersionGate(version.data);
    exitCode = mock::runCapture({mock::mockPath(), "status", "--json"}, mock::mockEnv(p.state), out);
    EnvelopeResult status = parseEnvelope(out, exitCode);
    if (status.outcome != CliOutcome::Ok) return p;
    p.status = parseStatusRows(status.data);
    p.ok = p.status.ok;
    return p;
}

static void testMockDefault() {
    g_context = "mock-default";
    Pipeline p = mockPipeline("default");
    CHECK(p.ok && p.gate.passed(), "default: gate passes and status parses");
    CountingAccess io(posixSidecarFileAccess());
    MemberLoadStats stats;
    MemberTable table = loadMembers(p.status.records, io, nullptr, statusHasVisual, &stats);
    // 16 roots in 14 directories: the gc_done tombstone is skipped, the 12
    // lone roots are assumed whole-directory without I/O, and only Loose
    // Tracks (two albums and a single, all virtual) is listed and read.
    CHECK_EQ(io.lists, 1, "1 directory listing for 16 roots");
    CHECK_EQ(io.reads, 3, "3 sidecar reads (the virtual roots)");
    CHECK(stats.directories == 14 && stats.directoriesSkipped == 1 && stats.directoriesAssumed == 12 &&
              stats.directoriesListed == 1,
          "14 directories: 1 listed, 12 assumed, the tombstone skipped");
    auto s = IntakeSnapshot::build(p.status.records, table);
    const std::string dump = p.root + "/income/dump/";
    const std::string shop = p.root + "/income/shop/";

    const IntakeRecord *b1 = s->lookup(shop + "Loose Tracks/Fixture Artist B - Loose One.wav");
    CHECK(b1 && b1->id == "itk_00000016", "a virtual root's member");
    CHECK(b1 && b1->visual.bgTint == 0x4A90D938 && b1->visual.tooltip == "needs review",
          "new + needs_review: blue with the tooltip");
    const IntakeRecord *c1 = s->lookup(shop + "Loose Tracks/Fixture Artist C - Other One.wav");
    CHECK(c1 && c1->id == "itk_00000017" && c1->visual.icon == IntakeIcon::CircleOpen,
          "the other virtual root in the same folder");
    const IntakeRecord *f = s->lookup(dump + "Fixture Artist - Overridden Album/01 - Test Track One.wav");
    CHECK(f && f->id == "itk_0000000f" && f->visual.bgTint == 0xE5A50A38 &&
              f->visual.icon == IntakeIcon::CircleLeftHalf,
          "user-assigned proposal with needs_review: amber half circle");
    const IntakeRecord *c = s->lookup(dump + "Fixture Artist - Unsure Album/02 - Test Track Two.wav");
    CHECK(c && c->visual.icon == IntakeIcon::Warning, "resolved + needs_review without a proposal: amber warning");
    const IntakeRecord *e = s->lookup(dump + "Fixture Artist - Close Call/01 - Test Track One.wav");
    CHECK(e && e->visual.bgTint == 0xE5A50A38, "engine proposal with needs_review: amber");
    const IntakeRecord *d = s->lookup(dump + "Fixture Artist - Proposed Album/01 - Test Track One.wav");
    CHECK(d && d->visual.bgTint == 0x2AA19838 && d->visual.icon == IntakeIcon::CircleLeftHalf, "proposed: teal");
    const IntakeRecord *ap = s->lookup(dump + "Fixture Artist - Approved Album/01 - Test Track One.wav");
    CHECK(ap && ap->visual.icon == IntakeIcon::CircleRightHalf, "approved: right half circle");
    const IntakeRecord *pl = s->lookup(dump + "Fixture Artist - Placing Album/01 - Test Track One.wav");
    CHECK(pl && pl->visual.icon == IntakeIcon::ArrowRight && pl->visual.tooltip == kTooltipPlacing,
          "placing: arrow and tooltip");
    const IntakeRecord *pd = s->lookup(dump + "Fixture Artist - Placed Album/01 - Test Track One.wav");
    CHECK(pd && pd->visual.icon == IntakeIcon::CircleFilled && pd->visual.bgTint == 0x3FB95038, "placed: green");
    const IntakeRecord *gc = s->lookup(dump + "Fixture Artist - Collected Album/01 - Test Track One.wav");
    CHECK(gc && gc->id == "itk_00000013" && gc->visual.isNone(), "gc_done: matched, renders nothing");
    const IntakeRecord *rj = s->lookup(dump + "Fixture Artist - Rejected Album/01 - Test Track One.wav");
    CHECK(rj && rj->visual.strikethrough && rj->visual.icon == IntakeIcon::Cross, "rejected: struck, cross");
    const IntakeRecord *va = s->lookup(dump + "Various Artists - Test Compilation/01 - Test Track One.wav");
    CHECK(va && va->proposal.targetPathState == TargetPathState::Set &&
              va->proposal.targetPath.find("/[Compilations]/") != std::string::npos && va->visual.tooltip.empty(),
          "Various Artists (CLI 0.3.0): a [Compilations] target, no slot pending");
    const IntakeRecord *single = s->lookup(shop + "Loose Tracks/Fixture Artist E - Single Track.wav");
    CHECK(single && single->id == "itk_00000019" && single->visual.icon == IntakeIcon::Warning &&
              single->visual.bgTint == 0xE5A50A38 && single->visual.tooltip == kTooltipSlotPending,
          "the single (null target, needs_review): amber warning, slot pending");
    CHECK(s->lookup(p.root + "/library/music.hq/Test Collection A/Fixture Artist/"
                             "Fixture Artist - 2026 - Placed Album/01 - Test Track One.wav") == nullptr,
          "a library copy is not an intake row");

    g_context = "mock-default-reload";
    // A second load while one named sidecar is half-written: the member
    // list of the last snapshot is kept, so the row keeps its root.
    CountingAccess torn(posixSidecarFileAccess());
    torn.garbleSuffix = ".intake.itk_00000016.json";
    MemberLoadStats again;
    MemberTable reloaded = loadMembers(p.status.records, torn, &s->members(), statusHasVisual, &again);
    auto s2 = IntakeSnapshot::build(p.status.records, reloaded);
    CHECK(again.sidecarRetries == 1 && again.keptPrevious == 1, "one retry, then the previous list");
    const IntakeRecord *kept = s2->lookup(shop + "Loose Tracks/Fixture Artist B - Loose Two.wav");
    CHECK(kept && kept->id == "itk_00000016", "the torn sidecar's root still owns its files");
}

static void testMockOld() {
    g_context = "mock-cli-0.2.1";
    Pipeline p = mockPipeline("cli-0.2.1");
    CHECK(p.ok && p.gate.passed() && !p.gate.info.hasCommands, "cli-0.2.1: gate passes without commands");
    MemberTable table = loadMembers(p.status.records, posixSidecarFileAccess(), nullptr, statusHasVisual);
    auto s = IntakeSnapshot::build(p.status.records, table);
    const std::string dump = p.root + "/income/dump/";
    const IntakeRecord *va = s->lookup(dump + "Various Artists - Test Compilation/01 - Test Track One.wav");
    CHECK(va && va->visual.tooltip.empty(), "0.2.1: no target_path, so no slot pending tooltip");
    const IntakeRecord *f = s->lookup(dump + "Fixture Artist - Overridden Album/01 - Test Track One.wav");
    CHECK(f && f->proposal.assignedBy == AssignedBy::Unknown && f->visual.bgTint == 0xE5A50A38,
          "0.2.1: assigned_by unknown, the needs_review override is amber");
    const IntakeRecord *b2 = s->lookup(p.root + "/income/shop/Loose Tracks/Fixture Artist B - Loose Two.wav");
    CHECK(b2 && b2->id == "itk_00000016", "0.2.1: virtual roots resolve");
    CHECK(s->recordForId("itk_00000019") == nullptr, "0.2.1: no single (a 0.3.0 fixture)");
}

int main(void) {
    atexit(mock::removeTempRoot);
    @autoreleasepool {
        testEmpty();
        testWholeDirectory();
        testSingles();
        testNested();
        testUnicode();
        testTiesAndKinds();
        testKeysAndVisuals();
        testConcurrentReaders();
        testTiming();
        testMockDefault();
        testMockOld();
    }
    mock::removeTempRoot();
    TEST_MAIN_END();
}
