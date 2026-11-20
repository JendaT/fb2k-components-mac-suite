//
//  IntakeLibraryIndexTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeLibraryIndex and the view's library lookup (B9):
//  every non-shadow file of a placed root under its library path (the same
//  rule as Swap, the prefix pair included), NFC/NFD and smbfs alias keys,
//  ties to the lowest id, the reverse lookup through IntakeView (a swapped
//  row maps to its root; roots that are not placed with placed.verified are
//  absent), and that decoration never uses it (library rows get no visual).
//  Synthetic paths only.
//
// TEST_DEPS: src/Core/IntakeSwapPlanner.mm src/Core/IntakeView.mm src/Core/IntakeSnapshot.mm
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeMountAliases.mm src/Core/IntakeSidecarMembers.mm
// TEST_DEPS: src/Core/IntakeEnvelope.mm src/Core/IntakeSettingsParse.mm src/Core/IntakeLog.mm
// TEST_DEPS: src/Core/IntakeDecorationMap.mm src/Core/IntakeReviewRule.mm src/Core/IntakeGroupBadge.mm
// TEST_DEPS: src/Core/IntakeErrorMap.mm src/Core/IntakeStatusModel.mm
// TEST_DEPS: src/Core/IntakeWatchSet.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeLibraryIndex.h"
#include "../src/Core/IntakePath.h"
#include "../src/Core/IntakeView.h"
#include "TestHarness.h"

#include <algorithm>
#include <string>
#include <vector>

using namespace intake;

namespace {

const std::string kNfc = "Caf\xC3\xA9";
const std::string kNfd = "Cafe\xCC\x81";

std::string key(const std::string &path) {
    std::string out;
    normalizePath(path, out);
    return out;
}

PlacedRootFiles placed(const std::string &id, const std::string &rootPath, const std::string &target,
                       std::vector<SidecarFile> files) {
    PlacedRootFiles r;
    r.id = id;
    r.rootPath = rootPath;
    r.rootKey = key(rootPath);
    r.targetPath = target;
    r.files = std::move(files);
    return r;
}

IntakeRecord record(const std::string &id, const std::string &rootPath, IntakeStatus status, bool verified,
                    const std::string &target) {
    IntakeRecord r;
    r.id = id;
    r.rootPath = rootPath;
    r.rootKey = key(rootPath);
    r.status = status;
    r.statusText = intakeStatusName(status);
    r.hasPlaced = !target.empty();
    r.placedVerified = verified;
    r.placedTargetPath = target;
    return r;
}

} // namespace

static void testBuild() {
    g_context = "build";
    const LibraryPrefix pair = makeLibraryPrefix("/nas/music", "/Volumes/music");
    std::vector<PlacedRootFiles> roots = {
        placed("itk_00000012", "/income/dump/Placed Album", "/nas/music/hq/A/Placed Album",
               {{"01 - One.wav", false}, {"02 - Two.wav", false}, {"03 - Shadow.wav", true}}),
        placed("itk_00000016", "/income/shop/Loose Tracks", "/nas/music/hq/B/Loose", {{"B - One.wav", false}}),
    };
    auto index = LibraryIndex::build(roots, pair, *MountAliases::none());
    CHECK(index->size() == 3 && index->rootCount() == 2, "three library paths of two roots (the shadow left out)");
    const std::string *hit = index->rootForKey(key("/Volumes/music/hq/A/Placed Album/01 - One.wav"));
    CHECK(hit && *hit == "itk_00000012", "a library path (after the prefix pair) maps to its root");
    hit = index->rootForKey(key("/Volumes/music/hq/B/Loose/B - One.wav"));
    CHECK(hit && *hit == "itk_00000016", "a virtual root's file");
    CHECK(index->rootForKey(key("/Volumes/music/hq/A/Placed Album/03 - Shadow.wav")) == nullptr,
          "a shadow has no library copy");
    CHECK(index->rootForKey(key("/nas/music/hq/A/Placed Album/01 - One.wav")) == nullptr,
          "the NAS spelling is not a row path once the pair maps it");
    CHECK(index->rootForKey(key("/income/dump/Placed Album/01 - One.wav")) == nullptr,
          "income paths are not in the library index");
    CHECK(index->rootForKey(key("/Volumes/music/hq/A/Placed Album")) == nullptr, "the folder itself is not a row");

    auto noPair = LibraryIndex::build(roots, LibraryPrefix(), *MountAliases::none());
    hit = noPair->rootForKey(key("/nas/music/hq/A/Placed Album/02 - Two.wav"));
    CHECK(hit && *hit == "itk_00000012", "no pair: the target path as reported");

    // Ties: two roots claim one library path; the lowest id wins, whatever
    // the order.
    std::vector<PlacedRootFiles> tie = {
        placed("itk_00000020", "/income/a", "/lib/X", {{"x.wav", false}}),
        placed("itk_0000001f", "/income/b", "/lib/X", {{"x.wav", false}}),
    };
    auto tieIndex = LibraryIndex::build(tie, LibraryPrefix(), *MountAliases::none());
    hit = tieIndex->rootForKey(key("/lib/X/x.wav"));
    CHECK(hit && *hit == "itk_0000001f", "a tie goes to the lowest id");
    std::reverse(tie.begin(), tie.end());
    auto reversed = LibraryIndex::build(tie, LibraryPrefix(), *MountAliases::none());
    hit = reversed->rootForKey(key("/lib/X/x.wav"));
    CHECK(hit && *hit == "itk_0000001f", "in either order");

    CHECK(LibraryIndex::empty()->isEmpty() && LibraryIndex::empty()->rootForKey("/x") == nullptr, "the empty index");
    std::vector<PlacedRootFiles> noTarget = {placed("itk_00000030", "/income/c", "", {{"a.wav", false}})};
    CHECK(LibraryIndex::build(noTarget, LibraryPrefix(), *MountAliases::none())->isEmpty(),
          "a root without a target path adds nothing");
}

static void testKeys() {
    g_context = "keys";
    // NFC sidecar paths, NFD rows (SMB), and the reverse.
    std::vector<PlacedRootFiles> roots = {
        placed("itk_00000012", "/income/" + kNfc, "/lib/" + kNfc, {{kNfc + ".wav", false}}),
    };
    auto index = LibraryIndex::build(roots, LibraryPrefix(), *MountAliases::none());
    const std::string *hit = index->rootForKey(key("/lib/" + kNfd + "/" + kNfd + ".wav"));
    CHECK(hit && *hit == "itk_00000012", "an NFD row finds an NFC library path");

    // The library on a share mounted twice: a row on either mount finds it.
    std::vector<MountEntry> mounts = {{"/", "/dev/disk1", "apfs", true},
                                      {"/Volumes/music", "//user@lan-host/music", "smbfs", false},
                                      {"/Volumes/music-1", "//user@vpn-host/music", "smbfs", false}};
    auto aliases = MountAliases::build(mounts);
    std::vector<PlacedRootFiles> share = {
        placed("itk_00000012", "/income/a", "/nas/music/hq/A/Album", {{"01.wav", false}}),
    };
    auto shared = LibraryIndex::build(share, makeLibraryPrefix("/nas/music", "/Volumes/music"), *aliases);
    hit = shared->rootForKey(aliases->rewritten(key("/Volumes/music-1/hq/A/Album/01.wav")));
    CHECK(hit && *hit == "itk_00000012", "a row on /Volumes/music-1 finds a library path under /Volumes/music");
    hit = shared->rootForKey(aliases->rewritten(key("/Volumes/music/hq/A/Album/01.wav")));
    CHECK(hit && *hit == "itk_00000012", "and one on /Volumes/music");
}

static void testViewLookup() {
    g_context = "view-lookup";
    const std::string income = "/income/dump/Placed Album";
    const std::string target = "/lib/hq/A/Placed Album";
    std::vector<IntakeRecord> records = {
        record("itk_00000012", income, IntakeStatus::Placed, true, target),
        record("itk_00000020", "/income/dump/Unverified", IntakeStatus::Placed, false, "/lib/hq/A/Unverified"),
        record("itk_00000013", "/income/dump/Collected", IntakeStatus::GcDone, true, "/lib/hq/C/Collected"),
    };
    // The index as the loader builds it: placed and verified roots only. The
    // gc_done and unverified roots are given here anyway, to check that the
    // view still refuses them.
    std::vector<PlacedRootFiles> files = {
        placed("itk_00000012", income, target, {{"01.wav", false}, {"02.wav", true}}),
        placed("itk_00000020", "/income/dump/Unverified", "/lib/hq/A/Unverified", {{"01.wav", false}}),
        placed("itk_00000013", "/income/dump/Collected", "/lib/hq/C/Collected", {{"01.wav", false}}),
    };
    auto index = LibraryIndex::build(files, LibraryPrefix(), *MountAliases::none());
    auto view = IntakeView::make(IntakeSnapshot::build(records, MemberTable()), MountAliases::none(), std::string(), index);
    ViewScratch scratch;

    const IntakeRecord *swapped = view->libraryRecordFor(target + "/01.wav", scratch);
    CHECK(swapped && swapped->id == "itk_00000012", "a row swapped to its library path maps to its root");
    CHECK(view->libraryRecordFor("file://" + target + "/01.wav", scratch) == swapped, "file:// rows too");
    CHECK(view->recordFor(target + "/01.wav", scratch) == nullptr, "recordFor (decorate) never uses the library index");
    CHECK(view->visualFor(target + "/01.wav", scratch) == nullptr, "a library row gets no visual");
    CHECK(view->libraryRecordFor(target + "/02.wav", scratch) == nullptr, "a shadow's would-be path: nothing");
    CHECK(view->libraryRecordFor("/lib/hq/A/Unverified/01.wav", scratch) == nullptr,
          "a placed root without placed.verified is absent");
    CHECK(view->libraryRecordFor("/lib/hq/C/Collected/01.wav", scratch) == nullptr, "a gc_done root is absent");
    CHECK(view->libraryRecordFor(income + "/01.wav", scratch) == nullptr, "an income row is not a library row");
    CHECK(view->recordFor(income + "/01.wav", scratch) != nullptr, "while recordFor still finds the income row");
    CHECK(view->libraryRecordFor("mac-volume://UUID/x.wav", scratch) == nullptr, "other schemes: nothing");

    auto plain = IntakeView::make(IntakeSnapshot::build(records, MemberTable()), MountAliases::none());
    CHECK(plain->library().isEmpty() && plain->libraryRecordFor(target + "/01.wav", scratch) == nullptr,
          "a view without an index");

    std::string matched;
    CHECK(view->matchKey("file:///lib//hq/./A/x.wav", scratch, matched) && matched == "/lib/hq/A/x.wav",
          "matchKey: the normalized key");
    CHECK(!view->matchKey("relative/x.wav", scratch, matched) && matched.empty(), "matchKey refuses relative paths");
}

int main() {
    @autoreleasepool {
        testBuild();
        testKeys();
        testViewLookup();
    }
    TEST_MAIN_END();
}
