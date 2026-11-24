//
//  IntakeFieldStateTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeFieldState (B13 item 4): FieldState::value() for
//  native, file:// and mac-volume rows (through the volume table and the
//  mount aliases of a share mounted twice), unknown volumes, other schemes,
//  inert and empty views, empty values, the remembered last row; rows with
//  non-ASCII names ruled out by their ASCII folder give the answers of the
//  full lookup (NFD and NFC, non-ASCII mount points, a mount inside a
//  share, ".."); the dirty set of view changes
//  (status, target, roots coming and going, member lists, inert, alias
//  tables) and of volume changes; the sequences where a host value was
//  computed with an older volume root; and a randomized check of the
//  refresh requirement: over many random sequences of views and volume
//  tables cut into refresh windows, every row whose value a host may still
//  hold differs from the current one only if the window's dirty set
//  matches it. Prints the time of 100,000 lookups, ASCII and NFD (printed,
//  not asserted).
//  Synthetic paths and ids only.
//
// TEST_DEPS: src/Core/IntakeView.mm src/Core/IntakeSnapshot.mm src/Core/IntakeVolumeTable.mm
// TEST_DEPS: src/Core/IntakeFields.mm src/Core/IntakeStatusModel.mm src/Core/IntakeTargetPath.mm
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeLog.mm src/Core/IntakeEnvelope.mm
// TEST_DEPS: src/Core/IntakeMountAliases.mm src/Core/IntakeSidecarMembers.mm src/Core/IntakeLibraryIndex.mm
// TEST_DEPS: src/Core/IntakeDecorationMap.mm src/Core/IntakeReviewRule.mm src/Core/IntakeGroupBadge.mm
// TEST_DEPS: src/Core/IntakeSettingsParse.mm src/Core/IntakeSwapPlanner.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeFieldState.h"
#include "../src/Core/IntakePath.h"
#include "../src/Core/IntakeSnapshot.h"
#include "TestHarness.h"

#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

using namespace intake;

static const std::string kIdA = "0A1B2C3D-0000-4000-8000-00000000000A";
static const std::string kIdB = "0A1B2C3D-0000-4000-8000-00000000000B";

static MountEntry smb(const std::string &mountPoint, const std::string &source) {
    return MountEntry{mountPoint, source, "smbfs"};
}

// The share "music" mounted once, or twice (LAN name and VPN address).
static std::shared_ptr<const MountAliases> musicOnce() {
    return MountAliases::build({smb("/Volumes/music", "//user@nas.local/music")});
}
static std::shared_ptr<const MountAliases> musicTwice() {
    return MountAliases::build(
        {smb("/Volumes/music", "//user@nas.local/music"), smb("/Volumes/music-1", "//user@10.0.0.2/music")});
}

struct Root {
    std::string id;
    std::string path;
    IntakeStatus status = IntakeStatus::Proposed;
    std::string collection;
    std::string target;  // empty: no target_path
};

static IntakeRecord makeRecord(const Root &root, const MountAliases &aliases) {
    IntakeRecord r;
    r.id = root.id;
    r.rootPath = root.path;
    std::string normalized;
    normalizePath(root.path, normalized);
    r.rootKey = aliases.rewritten(normalized);  // the loader's applyMountAliases
    r.status = root.status;
    r.statusText = intakeStatusName(root.status);
    if (!root.collection.empty() || !root.target.empty()) {
        r.hasProposal = true;
        r.proposal.targetCollection = root.collection;
        r.proposal.targetPathState = root.target.empty() ? TargetPathState::Null : TargetPathState::Set;
        r.proposal.targetPath = root.target;
    }
    return r;
}

static std::shared_ptr<const IntakeView> makeView(const std::vector<Root> &roots,
                                                  std::shared_ptr<const MountAliases> aliases,
                                                  MemberTable members = {}, std::string inert = std::string()) {
    if (!aliases) aliases = MountAliases::none();
    std::vector<IntakeRecord> records;
    for (const Root &r : roots) records.push_back(makeRecord(r, *aliases));
    return IntakeView::make(IntakeSnapshot::build(std::move(records), std::move(members)), aliases, std::move(inert));
}

static RootMembers memberList(std::vector<std::string> paths) {
    RootMembers m;
    m.kind = MemberKind::Members;
    m.source = MemberSource::Listed;
    m.relativePaths = std::move(paths);
    return m;
}

static std::string field(const FieldState &s, uint32_t index, const std::string &path) {
    FieldScratch scratch;
    std::string_view out;
    if (!s.value(index, path, scratch, out)) return "-";
    return std::string(out);
}

static std::string mv(const std::string &id, const std::string &rest) {
    return "mac-volume://" + id + "/" + rest;
}

// --- FieldState ---

static void testValues() {
    g_context = "values";
    const std::vector<Root> roots = {
        {"itk_00000001", "/income/dump/Fixture Artist - Album", IntakeStatus::Proposed, "Test Collection A",
         "/library/tier-hq/Test Collection A/Fixture Artist/Fixture Artist - 2026 - Album"},
        // The CLI names the share by its LAN mount; foobar2000 resolves
        // volume A to the VPN mount.
        {"itk_00000002", "/Volumes/music/income/Second", IntakeStatus::New},
    };
    auto view = makeView(roots, musicTwice());
    auto table = VolumeTable::make({{kIdA, "/Volumes/music-1"}});
    FieldState s(view, table);
    CHECK(s.showsValues(), "a loaded view shows values");

    const std::string native = "/income/dump/Fixture Artist - Album/01 Track.flac";
    CHECK(field(s, 0, native) == "proposed", "native: status");
    CHECK(field(s, 1, native) == "tier-hq/Test Collection A/Fixture Artist/Fixture Artist - 2026 - Album",
          "native: target");
    CHECK(field(s, 2, native) == "Test Collection A", "native: collection");
    CHECK(field(s, 0, "file://" + native) == "proposed", "file://: status");
    CHECK(field(s, 0, "FILE://" + native) == "proposed", "FILE://: status");
    CHECK(field(s, 3, native) == "-", "index past the end");

    const std::string share = mv(kIdA, "income/Second/CD1/01.flac");
    CHECK(field(s, 0, share) == "new", "mac-volume: through the table and the alias of the other mount");
    CHECK(field(s, 1, share) == "-", "no target: no field");
    CHECK(field(s, 2, share) == "-", "no collection: no field");
    CHECK(field(s, 0, mv(kIdB, "income/Second/01.flac")) == "-", "an unknown volume: no field");
    CHECK(field(s, 0, "/Volumes/music-1/income/Second/01.flac") == "new", "the native form of the same row");
    CHECK(field(s, 0, "/income/dump/Other/01.flac") == "-", "outside every root");
    CHECK(field(s, 0, "tidal://track/1") == "-", "another scheme");
    CHECK(field(s, 0, "") == "-", "empty");

    // The value views the record's own storage.
    FieldScratch scratch;
    std::string_view out;
    CHECK(s.value(0, native, scratch, out), "value() true");
    const IntakeRecord *rec = view->snapshot().recordForId("itk_00000001");
    CHECK(rec != nullptr && out.data() == rec->fields.status.data(), "no copy: a view of the record's value");
    CHECK(s.recordFor(share, scratch) == view->snapshot().recordForId("itk_00000002"), "recordFor");
}

static void testInertAndEmpty() {
    g_context = "inert and empty";
    const std::vector<Root> roots = {{"itk_00000001", "/income/a", IntakeStatus::Approved, "C", ""}};
    FieldState inert(makeView(roots, nullptr, {}, "schema 2"), nullptr);
    CHECK(!inert.showsValues(), "an inert view shows nothing");
    CHECK(field(inert, 0, "/income/a/x.flac") == "-", "inert: no field");

    FieldState none(nullptr, nullptr);
    CHECK(!none.showsValues() && none.view() && none.volumes(), "no view yet: empty view and table");
    CHECK(field(none, 0, "/income/a/x.flac") == "-", "no view: no field");

    FieldState empty(makeView({}, nullptr), nullptr);
    CHECK(!empty.showsValues(), "an empty view shows nothing");

    FieldState live(makeView(roots, nullptr), nullptr);
    CHECK(field(live, 0, "/income/a/x.flac") == "approved", "the same root, not inert");
    CHECK(field(live, 1, "/income/a/x.flac") == "-", "null target: no field");
    CHECK(field(live, 2, "/income/a/x.flac") == "C", "collection");
}

static void testMembers() {
    g_context = "members";
    const std::vector<Root> roots = {{"itk_00000005", "/income/singles", IntakeStatus::Resolved}};
    MemberTable members;
    members["itk_00000005"] = memberList({"s1.flac"});
    FieldState s(makeView(roots, nullptr, members), nullptr);
    CHECK(field(s, 0, "/income/singles/s1.flac") == "resolved", "a listed member");
    CHECK(field(s, 0, "/income/singles/s2.flac") == "-", "an unlisted file");
}

static void testLastRow() {
    g_context = "last row";
    const std::vector<Root> a = {{"itk_00000021", "/income/A", IntakeStatus::Proposed, "C1", ""}};
    const std::vector<Root> b = {{"itk_00000021", "/income/A", IntakeStatus::Approved, "C2", ""}};
    auto first = std::make_unique<FieldState>(makeView(a, nullptr), nullptr);
    FieldScratch scratch;
    std::string_view out;
    const std::string row = "/income/A/01.flac";
    const std::string other = "/income/B/01.flac";
    CHECK(first->value(0, row, scratch, out) && out == "proposed", "status");
    CHECK(scratch.lastSerial == first->serial() && scratch.lastPath == row, "the row is remembered");
    CHECK(first->value(2, row, scratch, out) && out == "C1", "the next field of the same row");
    const uint64_t firstSerial = first->serial();
    first.reset();  // retired: a later state may get the same memory
    auto second = std::make_unique<FieldState>(makeView(b, nullptr), nullptr);
    CHECK(second->serial() != firstSerial && second->serial() != 0, "every state has its own serial");
    CHECK(second->value(0, row, scratch, out) && out == "approved", "the same row in a later state: its value");
    CHECK(!second->value(0, other, scratch, out), "another row: no record");
    CHECK(!second->value(2, other, scratch, out), "remembered without a record too");
    CHECK(second->value(2, row, scratch, out) && out == "C2", "and back to the first row");
    // Compared by bytes, not by pointer: one buffer, another path in it.
    std::string buffer = row;
    CHECK(second->value(0, buffer, scratch, out), "a row in a reused buffer");
    buffer = other;
    CHECK(!second->value(0, buffer, scratch, out), "the same buffer holding another row");
}

// The lookup with no folder test: full normalisation, alias, snapshot.
static const IntakeRecord *slowRecordFor(const IntakeView &view, const std::string &path) {
    std::string key;
    if (normalizePath(path, key) != PathStatus::Ok) return nullptr;
    return view.snapshot().lookupKey(view.aliases().rewritten(key));
}

static void testNonASCIIRows() {
    g_context = "non-ASCII rows";
    const std::string nfd = "e\xCC\x81";  // "é" decomposed, as SMB shares store it
    const std::string nfc = "\xC3\xA9";   // "é" composed
    const std::vector<std::shared_ptr<const MountAliases>> tables = {
        MountAliases::none(),
        musicTwice(),
        // A share whose mount point has a non-ASCII name.
        MountAliases::build({smb("/Volumes/Caf" + nfc, "//user@nas.local/cafe"),
                             smb("/Volumes/music", "//user@nas.local/music")}),
        // A local disk mounted inside a share.
        MountAliases::build({smb("/Volumes/music", "//user@nas.local/music"),
                             MountEntry{"/Volumes/music/disk", "/dev/disk4s1", "hfs"}}),
    };
    const std::vector<Root> roots = {
        {"itk_00000011", "/Volumes/music/income/Caf" + nfd + " Album", IntakeStatus::New},
        {"itk_00000012", "/Volumes/music/income/Plain", IntakeStatus::Proposed},
        {"itk_00000013", "/Volumes/Caf" + nfc + "/in/A", IntakeStatus::Approved},
        {"itk_00000014", "/Volumes/music/disk/in/B", IntakeStatus::Placed},
        {"itk_00000015", "/Users/x/Caf" + nfc + "/C", IntakeStatus::Rejected},
    };
    const std::vector<std::string> heads = {
        "/Volumes/music/income", "/Volumes/music-1/income", "/Volumes/music/library/Artist",
        "/Volumes/music-1/library", "/Volumes/Caf" + nfd + "/in", "/Volumes/Caf" + nfc + "/in",
        "/Volumes/CAF" + nfc + "/in", "/Volumes/music/disk/in", "/Volumes/music-1/disk/in", "/Users/x",
        "/Users/x/Caf" + nfd, "/Users/y", "file:///Volumes/music/income", "/Volumes/music/income/../library",
        "/Volumes//music/./income", "/VOLUMES/MUSIC/income",
    };
    const std::vector<std::string> tails = {
        "Caf" + nfd + " Album/01.flac", "Caf" + nfc + " Album/CD1/01.flac", "Plain/0" + nfd + ".flac",
        "A/x" + nfd + ".flac", "B/" + nfd + ".flac", "C/" + nfc + "/1.flac", "Other " + nfd + "/1.flac",
        "Caf" + nfd + " Album/../Plain/" + nfd,
        // Pops out of a folder away from every root into one with roots.
        "Caf" + nfd + "/../../../income/Plain/x.flac", "Plain/01.flac",
    };
    size_t rows = 0, found = 0, ruledOut = 0, wrong = 0;
    for (const auto &aliases : tables) {
        auto view = makeView(roots, aliases);
        ViewScratch scratch;  // reused across rows, as decorate() and process_field do
        for (const std::string &h : heads) {
            for (const std::string &t : tails) {
                const std::string path = h + "/" + t;
                rows++;
                const IntakeRecord *slow = slowRecordFor(*view, path);
                if (slow != nullptr) found++;
                const bool may = view->mayHaveRecord(path, scratch);
                if (!may) ruledOut++;
                const IntakeRecord *fast = view->recordFor(path, scratch);
                if (fast != slow || (!may && slow != nullptr)) {
                    wrong++;
                    if (wrong <= 5) printf("    differs: %s (aliases: %s)\n", path.c_str(), aliases->describe().c_str());
                }
            }
        }
        // mac-volume rows through the volume table, one scratch for all.
        FieldState state(view, VolumeTable::make({{kIdA, "/Volumes/music-1"}, {kIdB, "/Volumes/Caf" + nfd}}));
        FieldScratch fieldScratch;
        for (const std::string &t : tails) {
            const std::pair<std::string, std::string> volumeRows[] = {
                {mv(kIdA, "income/" + t), "/Volumes/music-1/income/" + t},
                {mv(kIdA, "library/" + t), "/Volumes/music-1/library/" + t},
                {mv(kIdB, "in/" + t), "/Volumes/Caf" + nfd + "/in/" + t},
            };
            for (const auto &[row, native] : volumeRows) {
                rows++;
                const IntakeRecord *slow = slowRecordFor(*view, native);
                if (slow != nullptr) found++;
                if (state.recordFor(row, fieldScratch) != slow) {
                    wrong++;
                    if (wrong <= 5) printf("    differs: %s (aliases: %s)\n", row.c_str(), aliases->describe().c_str());
                }
            }
        }
    }
    printf("    %zu non-ASCII and ASCII rows: %zu under a root, %zu ruled out by their folder\n", rows, found,
           ruledOut);
    CHECK_EQ(wrong, 0, "the folder test never changes an answer");
    CHECK(found > 40, "rows under roots, in every spelling");
    CHECK(ruledOut > 100, "and many rows ruled out by their folder alone");
    CHECK(ruledOut + found < rows, "but not every other row (a mount below the folder, a \"..\", ASCII)");
}

static void testLookupTiming() {
    g_context = "timing";
    std::vector<Root> roots;
    for (int i = 0; i < 2000; i++) {
        roots.push_back({"itk_" + std::to_string(10000000 + i), "/Volumes/music/income/Artist " + std::to_string(i),
                         IntakeStatus::Proposed, "Test Collection A", ""});
    }
    FieldState s(makeView(roots, musicTwice()), VolumeTable::make({{kIdA, "/Volumes/music-1"}}));
    std::vector<std::string> paths;
    for (int i = 0; i < 1000; i++) {
        paths.push_back(mv(kIdA, "income/Artist " + std::to_string(i * 3) + "/CD1/0" + std::to_string(i % 10) +
                                     " Some Track Name.flac"));
    }
    FieldScratch scratch;
    std::string_view out;
    size_t hits = 0;
    const auto start = std::chrono::steady_clock::now();
    for (int round = 0; round < 100; round++) {
        for (const std::string &p : paths) {
            if (s.value(0, p, scratch, out)) hits++;
        }
    }
    const double ms =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    printf("    100,000 mac-volume field lookups over 2,000 roots: %.1f ms (%zu hits)\n", ms, hits);
    CHECK(hits > 0, "lookups hit");

    // Names stored decomposed (an SMB share): NFD "Tra" + U+0301 "ck" in
    // every row, half of them in the library outside every root (their
    // ASCII folder rules them out without NFC), half under a root.
    std::vector<std::string> nfd;
    for (int i = 0; i < 500; i++) {
        nfd.push_back(mv(kIdA, "library/Artist " + std::to_string(i) + "/Album/0" + std::to_string(i % 10) +
                                   " Some Tra\xCC\x81" "ck Name.flac"));
        nfd.push_back(mv(kIdA, "income/Artist " + std::to_string(i * 3) + "/CD1/0" + std::to_string(i % 10) +
                                   " Some Tra\xCC\x81" "ck Name.flac"));
    }
    size_t nfdHits = 0;
    const auto nfdStart = std::chrono::steady_clock::now();
    for (int round = 0; round < 100; round++) {
        for (const std::string &p : nfd) {
            if (s.value(0, p, scratch, out)) nfdHits++;
        }
    }
    const double nfdMs =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - nfdStart).count();
    printf("    100,000 NFD field lookups, half outside every root: %.1f ms (%zu hits)\n", nfdMs, nfdHits);
    CHECK_EQ(nfdHits, 50000, "every NFD row under a root hits, none outside");
}

// --- the dirty set ---

static bool dirty(const FieldDirtySet &d, const std::string &path, const VolumeTable &table) {
    FieldScratch scratch;
    return d.matches(path, table, scratch);
}

static void testViewChanges() {
    g_context = "view changes";
    const auto none = VolumeTable::empty();
    const std::vector<Root> base = {
        {"itk_00000001", "/income/a", IntakeStatus::Proposed, "C1", "/lib/tier/C1/A/R"},
        {"itk_00000002", "/income/b", IntakeStatus::New},
    };
    auto v1 = makeView(base, nullptr);

    FieldDirtySet d;
    addViewChanges(v1.get(), v1.get(), d);
    CHECK(d.empty(), "the same view: nothing");
    addViewChanges(v1.get(), IntakeView::make(v1->snapshotPtr(), v1->aliasesPtr()).get(), d);
    CHECK(d.empty(), "the same snapshot republished (library index): nothing");
    addViewChanges(v1.get(), makeView(base, nullptr).get(), d);
    CHECK(d.empty(), "a rebuilt snapshot with the same values (row colours): nothing");

    std::vector<Root> changed = base;
    changed[0].status = IntakeStatus::Approved;
    d = FieldDirtySet();
    addViewChanges(v1.get(), makeView(changed, nullptr).get(), d);
    CHECK(dirty(d, "/income/a/01.flac", *none), "status changed: its rows");
    CHECK(dirty(d, "file:///income/a/sub/02.flac", *none), "and deeper ones, file:// too");
    CHECK(!dirty(d, "/income/b/01.flac", *none), "not the other root's rows");
    CHECK(!dirty(d, "/income/ab/01.flac", *none), "not a sibling sharing the prefix");
    CHECK(!dirty(d, "tidal://x", *none), "never another scheme");

    changed = base;
    changed[0].target = "/lib/tier/C1/A/R2";
    d = FieldDirtySet();
    addViewChanges(v1.get(), makeView(changed, nullptr).get(), d);
    CHECK(dirty(d, "/income/a/01.flac", *none) && !dirty(d, "/income/b/01.flac", *none), "target changed");

    changed = base;
    changed[1].collection = "C2";
    d = FieldDirtySet();
    addViewChanges(v1.get(), makeView(changed, nullptr).get(), d);
    CHECK(dirty(d, "/income/b/01.flac", *none) && !dirty(d, "/income/a/01.flac", *none), "collection changed");

    changed = base;
    changed.push_back({"itk_00000003", "/income/a/nested", IntakeStatus::Resolved});
    d = FieldDirtySet();
    addViewChanges(v1.get(), makeView(changed, nullptr).get(), d);
    CHECK(dirty(d, "/income/a/nested/01.flac", *none), "a nested root came: its rows");
    CHECK(!dirty(d, "/income/a/01.flac", *none), "not the parent's other rows");
    d = FieldDirtySet();
    addViewChanges(makeView(changed, nullptr).get(), v1.get(), d);
    CHECK(dirty(d, "/income/a/nested/01.flac", *none), "a nested root went: its rows");

    changed = base;
    changed[1].path = "/income/b-moved";
    d = FieldDirtySet();
    addViewChanges(v1.get(), makeView(changed, nullptr).get(), d);
    CHECK(dirty(d, "/income/b/01.flac", *none) && dirty(d, "/income/b-moved/01.flac", *none),
          "a root moved: old and new rows");

    MemberTable m1;
    m1["itk_00000002"] = memberList({"s1.flac"});
    MemberTable m2;
    m2["itk_00000002"] = memberList({"s1.flac", "s2.flac"});
    d = FieldDirtySet();
    addViewChanges(makeView(base, nullptr, m1).get(), makeView(base, nullptr, m2).get(), d);
    CHECK(dirty(d, "/income/b/s2.flac", *none), "a member list grew: the new member");
    CHECK(!dirty(d, "/income/a/01.flac", *none), "not another root");
}

static void testInertChanges() {
    g_context = "inert changes";
    const auto none = VolumeTable::empty();
    const std::vector<Root> base = {{"itk_00000001", "/income/a", IntakeStatus::Proposed, "C1", ""}};
    auto live = makeView(base, nullptr);
    auto inert = makeView(base, nullptr, {}, "schema 2");
    auto inert2 = makeView(base, nullptr, {}, "E_NO_CLI");

    FieldDirtySet d;
    addViewChanges(inert.get(), inert2.get(), d);
    CHECK(d.empty(), "inert to inert: nothing had a value");
    addViewChanges(nullptr, inert.get(), d);
    CHECK(d.empty(), "nothing to inert: nothing");
    addViewChanges(inert.get(), live.get(), d);
    CHECK(dirty(d, "/income/a/01.flac", *none), "inert to live: every root's rows");
    d = FieldDirtySet();
    addViewChanges(live.get(), inert.get(), d);
    CHECK(dirty(d, "/income/a/01.flac", *none), "live to inert: every root's rows");
    d = FieldDirtySet();
    addViewChanges(nullptr, live.get(), d);
    CHECK(dirty(d, "/income/a/01.flac", *none), "the first view: every root's rows");
    d = FieldDirtySet();
    addViewChanges(live.get(), makeView({}, nullptr).get(), d);
    CHECK(dirty(d, "/income/a/01.flac", *none), "to an empty view (reconfigured): every root's rows");
}

static void testAliasChange() {
    g_context = "alias change";
    // The CLI root is under /Volumes/music. A row under /Volumes/music-1
    // matches it only once the second mount is aliased too: the root's key
    // ("/smbfs:music/income/a") is the same in both views.
    const std::vector<Root> base = {{"itk_00000001", "/Volumes/music/income/a", IntakeStatus::Proposed, "C1", ""}};
    auto once = makeView(base, musicOnce());
    auto twice = makeView(base, musicTwice());
    const auto none = VolumeTable::empty();
    FieldState before(once, none);
    FieldState after(twice, none);
    const std::string row = "/Volumes/music-1/income/a/01.flac";
    CHECK(field(before, 0, row) == "-" && field(after, 0, row) == "proposed", "the row's value changed");
    FieldDirtySet d;
    addViewChanges(once.get(), twice.get(), d);
    CHECK(dirty(d, row, *none), "so it is dirty");
    CHECK_EQ(d.groupCount(), 2, "keys kept per alias table");
}

static void testVolumeChanges() {
    g_context = "volume changes";
    const std::vector<Root> base = {
        {"itk_00000001", "/Volumes/music/income/a", IntakeStatus::Proposed, "C1", ""},
        {"itk_00000002", "/income/local", IntakeStatus::New},
    };
    auto view = makeView(base, musicTwice());
    auto empty = VolumeTable::empty();
    auto learned = empty->withVolume(kIdA, "/Volumes/music-1");

    FieldDirtySet d;
    addVolumeChanges(*empty, *empty, view.get(), d);
    CHECK(d.empty(), "no change: nothing");
    addVolumeChanges(*learned, *VolumeTable::make({{kIdA, "/Volumes/music-1"}}), view.get(), d);
    CHECK(d.empty(), "the same table: nothing");

    addVolumeChanges(*empty, *learned, view.get(), d);
    CHECK(dirty(d, mv(kIdA, "income/a/01.flac"), *learned), "a learned volume: its rows under a root");
    CHECK(!dirty(d, mv(kIdA, "elsewhere/01.flac"), *learned), "not its rows outside every root");
    CHECK(!dirty(d, mv(kIdB, "income/a/01.flac"), *learned), "not another (unknown) volume's rows");

    d = FieldDirtySet();
    addVolumeChanges(*empty, *learned, makeView(base, musicTwice(), {}, "schema 2").get(), d);
    CHECK(d.empty(), "an inert view: no key");
    addVolumeChanges(*empty, *learned, nullptr, d);
    CHECK(d.empty(), "no view: no key");
}

// (V1, T) -> (V2, T) -> (V2, T'): a host value from (V1, T) was computed
// with the volume's old root; the row must still be caught with T' current.
static void testOldRootAfterViewChange() {
    g_context = "old root after a view change";
    const std::vector<Root> v1Roots = {{"itk_00000001", "/Volumes/a/income/R", IntakeStatus::Proposed, "C1", ""}};
    const std::vector<Root> v2Roots = {{"itk_00000002", "/Volumes/b/other", IntakeStatus::New}};
    auto v1 = makeView(v1Roots, nullptr);
    auto v2 = makeView(v2Roots, nullptr);
    auto t = VolumeTable::make({{kIdA, "/Volumes/a"}});
    auto t2 = VolumeTable::make({{kIdA, "/Volumes/b"}});
    const std::string row = mv(kIdA, "income/R/01.flac");
    CHECK(field(FieldState(v1, t), 0, row) == "proposed", "the host saw a value");
    CHECK(field(FieldState(v2, t2), 0, row) == "-", "now none");

    FieldDirtySet d;
    addViewChanges(v1.get(), v2.get(), d);
    addVolumeChanges(*t, *t2, v2.get(), d);
    CHECK(dirty(d, row, *t2), "caught through the noted old root");

    // (V1, T) -> (V1, T') -> (V2, T').
    FieldDirtySet e;
    addVolumeChanges(*t, *t2, v1.get(), e);
    addViewChanges(v1.get(), v2.get(), e);
    CHECK(dirty(e, row, *t2), "the other order");

    // A noted root alone dirties nothing.
    FieldDirtySet f;
    f.noteVolumeRoot(kIdA, "/Volumes/a");
    CHECK(f.empty() && !dirty(f, row, *t2), "noted roots alone: nothing");
}

// --- randomized check of the refresh requirement ---

struct Rng {
    uint64_t s;
    explicit Rng(uint64_t seed) : s(seed * 2654435761u + 1) {}
    uint32_t next() {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return static_cast<uint32_t>(s >> 11);
    }
    uint32_t below(uint32_t n) { return next() % n; }
    bool chance(uint32_t percent) { return below(100) < percent; }
};

struct World {
    std::vector<std::shared_ptr<const MountAliases>> aliasTables;
    std::vector<std::string> rows;
};

static World makeWorld() {
    World w;
    w.aliasTables = {MountAliases::none(), musicOnce(), musicTwice()};
    const std::vector<std::string> rests = {
        "income/A/01.flac",  "income/A/CD2/01.flac", "income/B/01.flac",  "in/C/01.flac",
        "income/S/s1.flac",  "income/S/s2.flac",     "income/x.flac",     "other/y.flac",
    };
    for (const std::string &id : {kIdA, kIdB}) {
        for (const std::string &r : rests) w.rows.push_back(mv(id, r));
    }
    for (const std::string &mount : {"/Volumes/music", "/Volumes/music-1", "/Volumes/usb"}) {
        for (const std::string &r : rests) w.rows.push_back(std::string(mount) + "/" + r);
    }
    w.rows.push_back("file:///Users/x/income/D/01.flac");
    w.rows.push_back("/Users/x/income/D/sub/02.flac");
    w.rows.push_back("tidal://track/1");
    return w;
}

// The random state of one candidate root; a view is built from all seven.
struct RootState {
    bool present = false;
    bool moved = false;      // another root_path for the same id
    uint32_t status = 0;     // index into kStatuses
    uint32_t collection = 0; // index into kCollections
    int target = -1;         // -1: no target_path, else which release name
    bool twoMembers = false; // itk_00000006: lists s2.flac too
    bool noMembers = false;  // itk_00000007: MemberKind::None
};

struct ViewState {
    RootState roots[7];
    bool inert = false;
    uint32_t aliases = 0;  // index into World::aliasTables
};

static const IntakeStatus kStatuses[] = {IntakeStatus::New, IntakeStatus::Proposed, IntakeStatus::Rejected};
static const char *kCollections[] = {"", "C1", "C2"};

static void randomizeRoot(Rng &rng, RootState &r, uint32_t what) {
    switch (what) {
        case 0: r.present = rng.chance(60); break;
        case 1: r.moved = rng.chance(15); break;
        case 2: r.status = rng.below(3); break;
        case 3: r.collection = rng.below(3); break;
        case 4: r.target = static_cast<int>(rng.below(3)) - 1; break;
        case 5: r.twoMembers = rng.chance(50); break;
        default: r.noMembers = rng.chance(30); break;
    }
}

static ViewState randomViewState(Rng &rng) {
    ViewState v;
    for (RootState &r : v.roots) {
        for (uint32_t what = 0; what < 7; what++) randomizeRoot(rng, r, what);
    }
    v.inert = rng.chance(15);
    v.aliases = rng.below(3);
    return v;
}

// One step: usually a single attribute of one root changes, so changes of
// one kind alone (a member list, a target) are common; sometimes the
// inert state, the alias table, or everything.
static ViewState nextViewState(Rng &rng, ViewState v) {
    const uint32_t pick = rng.below(100);
    if (pick < 10) return randomViewState(rng);
    if (pick < 18) {
        v.inert = !v.inert;
    } else if (pick < 26) {
        v.aliases = rng.below(3);
    } else {
        randomizeRoot(rng, v.roots[rng.below(7)], rng.below(7));
    }
    return v;
}

static std::shared_ptr<const IntakeView> buildView(const ViewState &v, const World &w) {
    struct Candidate {
        const char *id;
        const char *path;
    };
    static const Candidate candidates[7] = {
        {"itk_00000001", "/Volumes/music/income/A"},  {"itk_00000002", "/Volumes/music-1/income/B"},
        {"itk_00000003", "/Volumes/usb/in/C"},        {"itk_00000004", "/Users/x/income/D"},
        {"itk_00000005", "/Volumes/music/income/A/CD2"}, {"itk_00000006", "/Volumes/music/income/S"},
        {"itk_00000007", "/Volumes/music/income"},
    };
    std::vector<Root> roots;
    MemberTable members;
    for (int i = 0; i < 7; i++) {
        const RootState &s = v.roots[i];
        if (!s.present) continue;
        Root r;
        r.id = candidates[i].id;
        r.path = std::string(candidates[i].path) + (s.moved ? "-moved" : "");
        r.status = kStatuses[s.status];
        r.collection = kCollections[s.collection];
        if (s.target >= 0) r.target = "/lib/tier/" + r.collection + "/Art/Rel" + std::to_string(s.target);
        roots.push_back(r);
        if (i == 5) members[r.id] = s.twoMembers ? memberList({"s1.flac", "s2.flac"}) : memberList({"s1.flac"});
        if (i == 6 && s.noMembers) {
            RootMembers none;
            none.kind = MemberKind::None;
            members[r.id] = none;
        }
    }
    return makeView(roots, w.aliasTables[v.aliases], std::move(members), v.inert ? "schema 2" : std::string());
}

static std::shared_ptr<const VolumeTable> randomTable(Rng &rng) {
    static const char *rootsA[] = {nullptr, "/Volumes/music", "/Volumes/music-1"};
    static const char *rootsB[] = {nullptr, "/Volumes/music-1", "/Volumes/usb"};
    std::vector<VolumeEntry> entries;
    if (const char *a = rootsA[rng.below(3)]) entries.push_back({kIdA, a});
    if (const char *b = rootsB[rng.below(3)]) entries.push_back({kIdB, b});
    return VolumeTable::make(std::move(entries));
}

static std::string rowValues(const FieldState &s, const std::string &row) {
    return field(s, 0, row) + "|" + field(s, 1, row) + "|" + field(s, 2, row);
}

static void testRandomSequences() {
    g_context = "random sequences";
    const World w = makeWorld();
    size_t refreshes = 0;
    size_t changedRows = 0;
    size_t refreshedRows = 0;
    size_t missed = 0;
    for (uint64_t seed = 1; seed <= 600; seed++) {
        Rng rng(seed);
        ViewState vs = randomViewState(rng);
        std::shared_ptr<const IntakeView> view = rng.chance(20) ? nullptr : buildView(vs, w);
        std::shared_ptr<const VolumeTable> table = randomTable(rng);
        auto state = std::make_shared<FieldState>(view, table);
        // What a host may hold per row: every value since its last refresh.
        std::vector<std::vector<std::string>> held(w.rows.size());
        for (size_t i = 0; i < w.rows.size(); i++) held[i].push_back(rowValues(*state, w.rows[i]));
        FieldDirtySet d;
        const int steps = 16;
        for (int step = 0; step < steps; step++) {
            if (rng.chance(55)) {
                vs = nextViewState(rng, vs);
                std::shared_ptr<const IntakeView> next = buildView(vs, w);
                addViewChanges(view.get(), next.get(), d);
                view = next;
            } else {
                std::shared_ptr<const VolumeTable> next = randomTable(rng);
                addVolumeChanges(*table, *next, view.get(), d);
                table = next;
            }
            state = std::make_shared<FieldState>(view, table);
            for (size_t i = 0; i < w.rows.size(); i++) {
                const std::string v = rowValues(*state, w.rows[i]);
                if (held[i].back() != v) held[i].push_back(v);
            }
            const bool refreshNow = rng.chance(35) || step == steps - 1;
            if (!refreshNow) continue;
            refreshes++;
            for (size_t i = 0; i < w.rows.size(); i++) {
                const std::string &now = held[i].back();
                bool differs = false;
                for (const std::string &v : held[i]) differs = differs || v != now;
                const bool hit = dirty(d, w.rows[i], *table);
                if (differs) changedRows++;
                if (hit) refreshedRows++;
                if (differs && !hit) {
                    missed++;
                    if (missed <= 5) printf("    missed: seed %llu step %d row %s\n",
                                            static_cast<unsigned long long>(seed), step, w.rows[i].c_str());
                }
                if (hit) held[i] = {now};
            }
            d = FieldDirtySet();
        }
    }
    printf("    %zu refreshes: %zu rows changed, %zu refreshed (a superset is allowed)\n", refreshes, changedRows,
           refreshedRows);
    CHECK_EQ(missed, 0, "no row whose held value differs goes unrefreshed");
    CHECK(changedRows > 100, "the sequences change rows");
    CHECK(refreshedRows < refreshes * w.rows.size(), "and do not refresh everything every time");
}

int main(void) {
    @autoreleasepool {
        testValues();
        testInertAndEmpty();
        testMembers();
        testLastRow();
        testNonASCIIRows();
        testLookupTiming();
        testViewChanges();
        testInertChanges();
        testAliasChange();
        testVolumeChanges();
        testOldRootAfterViewChange();
        testRandomSequences();
    }
    TEST_MAIN_END();
}
