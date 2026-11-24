//
//  IntakeVolumeTableTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeVolumeTable (B13 item 4): splitting mac-volume
//  paths, the volume id of a canonical root, roots from native paths, the
//  learn check (raw remainder; an encoded one is refused), the table's
//  lookups ignoring ASCII case, the copy-on-write learn, the re-seed merge
//  and the change list. Synthetic ids and mount names only.
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeVolumeTable.h"
#include "TestHarness.h"

#include <string>
#include <vector>

using namespace intake;

static const std::string kIdA = "0A1B2C3D-0000-4000-8000-00000000000A";
static const std::string kIdB = "0A1B2C3D-0000-4000-8000-00000000000B";

static std::string lower(std::string s) {
    for (char &c : s) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return s;
}

static void testSplit() {
    g_context = "split";
    std::string_view uuid;
    std::string_view rest;
    const std::string path = "mac-volume://" + kIdA + "/income/a.flac";  // the views point into it
    CHECK(splitMacVolumePath(path, uuid, rest), "a mac-volume path");
    CHECK(uuid == kIdA && rest == "income/a.flac", "id and remainder");

    const std::string mixed = "MAC-Volume://" + kIdA + "/x";
    CHECK(splitMacVolumePath(mixed, uuid, rest) && uuid == kIdA && rest == "x", "the scheme ignores case");

    const std::string rootOnly = "mac-volume://" + kIdA + "/";
    CHECK(splitMacVolumePath(rootOnly, uuid, rest) && uuid == kIdA && rest.empty(), "the root: empty remainder");
    const std::string noSlash = "mac-volume://" + kIdA;
    CHECK(splitMacVolumePath(noSlash, uuid, rest) && uuid == kIdA && rest.empty(), "no slash: empty remainder");

    CHECK(!splitMacVolumePath("mac-volume:///x", uuid, rest), "an empty id");
    CHECK(!splitMacVolumePath("mac-volume://", uuid, rest), "the bare scheme");
    CHECK(!splitMacVolumePath("file:///Volumes/share/x", uuid, rest), "file://");
    CHECK(!splitMacVolumePath("/Volumes/share/x", uuid, rest), "a native path");
    CHECK(!splitMacVolumePath("tidal://track/1", uuid, rest), "another scheme");
    CHECK(!splitMacVolumePath("", uuid, rest), "empty");
}

static void testVolumeIdOfRoot() {
    g_context = "volume id of root";
    CHECK(volumeIdOfRoot("mac-volume://" + kIdA + "/") == kIdA, "with the slash");
    CHECK(volumeIdOfRoot("mac-volume://" + kIdA) == kIdA, "without it");
    CHECK(volumeIdOfRoot("mac-volume://" + kIdA + "/sub").empty(), "a path below the root");
    CHECK(volumeIdOfRoot("file:///Volumes/share/").empty(), "file:// (a volume foobar2000 keeps as a path)");
    CHECK(volumeIdOfRoot("/Volumes/share/").empty(), "native");
    CHECK(volumeIdOfRoot("").empty(), "empty (the call threw)");
}

static void testRootFromNative() {
    g_context = "root from native";
    CHECK(volumeRootFromNative("/Volumes/share-1/") == "/Volumes/share-1", "trailing slash removed");
    CHECK(volumeRootFromNative("/Volumes/share-1//") == "/Volumes/share-1", "all of them");
    CHECK(volumeRootFromNative("/Volumes/share-1") == "/Volumes/share-1", "none to remove");
    CHECK(volumeRootFromNative("/") == "/", "the root stays");
    CHECK(volumeRootFromNative("Volumes/x").empty(), "relative");
    CHECK(volumeRootFromNative("").empty(), "empty");
}

static void testLearnedRoot() {
    g_context = "learned root";
    const std::string row = "mac-volume://" + kIdA + "/income/Fixture Artist - Album/01 Track.flac";
    CHECK(learnedVolumeRoot(row, "/Volumes/share-1/income/Fixture Artist - Album/01 Track.flac") == "/Volumes/share-1",
          "the native path without the row's remainder");
    CHECK(learnedVolumeRoot(row, "/Volumes/share-1/income/Fixture%20Artist%20-%20Album/01%20Track.flac").empty(),
          "a remainder spelled differently (percent-encoded) is refused");
    CHECK(learnedVolumeRoot(row, "/Volumes/share-1/other/01 Track.flac").empty(), "another remainder");
    CHECK(learnedVolumeRoot(row, "income/Fixture Artist - Album/01 Track.flac").empty(), "nothing left for the root");
    CHECK(learnedVolumeRoot(row, "/income/Fixture Artist - Album/01 Track.flac").empty(), "only \"/\" left");
    CHECK(learnedVolumeRoot(row, "x/income/Fixture Artist - Album/01 Track.flac").empty(), "a relative root");
    CHECK(learnedVolumeRoot(row, "/Volumes/share-1income/Fixture Artist - Album/01 Track.flac").empty(),
          "no '/' between root and remainder");
    CHECK(learnedVolumeRoot("mac-volume://" + kIdA + "/", "/Volumes/share-1/").empty(), "an empty remainder");
    CHECK(learnedVolumeRoot("/Volumes/share-1/a.flac", "/Volumes/share-1/a.flac").empty(), "not a mac-volume row");
    const std::string nfd = "mac-volume://" + kIdA + "/Cafe\xCC\x81/a.flac";
    CHECK(learnedVolumeRoot(nfd, "/Volumes/m/Cafe\xCC\x81/a.flac") == "/Volumes/m", "raw bytes, NFD kept");
}

static void testTable() {
    g_context = "table";
    auto t = VolumeTable::make({{kIdA, "/Volumes/share-1"}, {kIdB, "/Volumes/usb"}, {lower(kIdA), "/Volumes/other"},
                                {"", "/Volumes/x"}, {"C", ""}});
    CHECK_EQ(t->size(), 2, "empty ids and roots skipped, the first of an id wins");
    CHECK(t->rootFor(kIdA) && *t->rootFor(kIdA) == "/Volumes/share-1", "A");
    CHECK(t->rootFor(lower(kIdA)) && *t->rootFor(lower(kIdA)) == "/Volumes/share-1", "A in lower case");
    CHECK(t->rootFor(kIdB) && *t->rootFor(kIdB) == "/Volumes/usb", "B");
    CHECK(t->rootFor("0A1B2C3D") == nullptr, "a prefix of an id is not the id");

    std::string out = "stale";
    CHECK(t->nativePath("mac-volume://" + kIdA + "/income/a.flac", out) && out == "/Volumes/share-1/income/a.flac",
          "root + / + remainder");
    CHECK(t->nativePath("mac-volume://" + lower(kIdA) + "/b", out) && out == "/Volumes/share-1/b", "id case ignored");
    CHECK(t->nativePath("mac-volume://" + kIdA + "/", out) && out == "/Volumes/share-1", "the root itself");
    CHECK(!t->nativePath("mac-volume://FFFFFFFF-0000-4000-8000-000000000000/a", out), "an unknown volume");
    CHECK(!t->nativePath("/Volumes/share-1/a", out), "not a mac-volume path");
    CHECK(!t->nativePath("tidal://x", out), "another scheme");

    auto slash = VolumeTable::make({{kIdA, "/"}});
    CHECK(slash->nativePath("mac-volume://" + kIdA + "/a/b", out) && out == "/a/b", "a root of \"/\" adds no slash");

    auto e = VolumeTable::empty();
    CHECK(e->isEmpty() && e == VolumeTable::empty(), "one shared empty table");
    CHECK(!e->nativePath("mac-volume://" + kIdA + "/a", out), "the empty table knows nothing");
    CHECK(e->describe() == "none", "describe: none");
    CHECK(t->describe() == kIdA + " -> /Volumes/share-1; " + kIdB + " -> /Volumes/usb", "describe");
}

static void testWithVolume() {
    g_context = "withVolume";
    auto t = VolumeTable::make({{kIdA, "/Volumes/share"}});
    auto u = t->withVolume(kIdB, "/Volumes/share-1");
    CHECK_EQ(t->size(), 1, "the original is unchanged");
    CHECK_EQ(u->size(), 2, "the copy has both");
    CHECK(u->rootFor(kIdB) && *u->rootFor(kIdB) == "/Volumes/share-1", "the learned volume");
    auto v = u->withVolume(lower(kIdA), "/Volumes/moved");
    CHECK_EQ(v->size(), 2, "an id given again replaces its entry");
    CHECK(v->rootFor(kIdA) && *v->rootFor(kIdA) == "/Volumes/moved", "the new root wins");
}

static void testSameAs() {
    g_context = "sameAs";
    auto a = VolumeTable::make({{kIdA, "/Volumes/a"}, {kIdB, "/Volumes/b"}});
    auto b = VolumeTable::make({{kIdB, "/Volumes/b"}, {lower(kIdA), "/Volumes/a"}});
    CHECK(a->sameAs(*b) && b->sameAs(*a), "order and id case do not matter");
    auto c = VolumeTable::make({{kIdA, "/Volumes/a"}, {kIdB, "/Volumes/c"}});
    CHECK(!a->sameAs(*c), "a moved root");
    auto d = VolumeTable::make({{kIdA, "/Volumes/a"}});
    CHECK(!a->sameAs(*d) && !d->sameAs(*a), "a missing id");
    CHECK(VolumeTable::empty()->sameAs(*VolumeTable::make({})), "two empty tables");
}

static void testMerge() {
    g_context = "merge";
    // Learned: B (a stale id of the share at /Volumes/share-1) and C (a
    // share no longer mounted). The seed finds A for /Volumes/share-1.
    const std::string kIdC = "0A1B2C3D-0000-4000-8000-00000000000C";
    auto previous = VolumeTable::make({{kIdB, "/Volumes/share-1"}, {kIdC, "/Volumes/gone"}, {kIdA, "/Volumes/old"}});
    auto merged = mergeSeededVolumes({{kIdA, "/Volumes/share-1"}}, *previous,
                                     {"/", "/System/Volumes/Data", "/Volumes/SHARE-1/"});
    CHECK(merged->rootFor(kIdA) && *merged->rootFor(kIdA) == "/Volumes/share-1", "the seed wins for its ids");
    CHECK(merged->rootFor(kIdB) && *merged->rootFor(kIdB) == "/Volumes/share-1",
          "a learned id whose root is still mounted is kept (case and trailing slash ignored)");
    CHECK(merged->rootFor(kIdC) == nullptr, "a learned id whose root is gone is dropped");
    CHECK_EQ(merged->size(), 2, "A and B");

    auto none = mergeSeededVolumes({}, *previous, {});
    CHECK(none->isEmpty(), "nothing mounted: nothing kept");
}

static void testChanges() {
    g_context = "changes";
    const std::string kIdC = "0A1B2C3D-0000-4000-8000-00000000000C";
    auto before = VolumeTable::make({{kIdA, "/Volumes/a"}, {kIdB, "/Volumes/b"}});
    auto after = VolumeTable::make({{lower(kIdA), "/Volumes/a"}, {kIdB, "/Volumes/b-1"}, {kIdC, "/Volumes/c"}});
    std::vector<VolumeChange> c = volumeChanges(*before, *after);
    CHECK_EQ(c.size(), 2, "B moved, C came; A unchanged (id case ignored)");
    bool sawB = false;
    bool sawC = false;
    for (const VolumeChange &x : c) {
        if (x.uuid == kIdB) sawB = x.before == "/Volumes/b" && x.after == "/Volumes/b-1";
        if (x.uuid == kIdC) sawC = x.before.empty() && x.after == "/Volumes/c";
    }
    CHECK(sawB, "B: old and new root");
    CHECK(sawC, "C: came");
    c = volumeChanges(*after, *before);
    bool goneC = false;
    for (const VolumeChange &x : c) {
        if (x.uuid == kIdC) goneC = x.before == "/Volumes/c" && x.after.empty();
    }
    CHECK(goneC, "C: went");
    CHECK(volumeChanges(*before, *before).empty(), "no change");
}

int main(void) {
    @autoreleasepool {
        testSplit();
        testVolumeIdOfRoot();
        testRootFromNative();
        testLearnedRoot();
        testTable();
        testWithVolume();
        testSameAs();
        testMerge();
        testChanges();
    }
    TEST_MAIN_END();
}
