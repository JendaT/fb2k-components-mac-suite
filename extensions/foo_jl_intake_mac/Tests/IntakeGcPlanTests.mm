//
//  IntakeGcPlanTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeGcPlan (B9, Delete local copy…): the local paths
//  (root_path + files[].path, shadows included), the confirmation's title
//  and text (at most 10 paths, then "and N more"; the whole-folder note;
//  unreadable roots; "Swap, then delete" while income rows remain), the
//  test aid's summary, and the recheck of the captured roots on confirm
//  (placed with placed.verified kept; gone, gc_done, rejected and
//  unverified roots dropped with a reason). Synthetic paths only.
//
// TEST_DEPS: src/Core/IntakeActionTable.mm src/Core/IntakeCapabilities.mm src/Core/IntakeCommandArgs.mm
// TEST_DEPS: src/Core/IntakeSemver.mm src/Core/IntakeSettingsParse.mm src/Core/IntakeReviewRule.mm
// TEST_DEPS: src/Core/IntakeStatusModel.mm src/Core/IntakeEnvelope.mm src/Core/IntakePath.mm
// TEST_DEPS: src/Core/IntakeLog.mm src/Core/IntakeErrorMap.mm src/Core/IntakeDecorationMap.mm
// TEST_DEPS: src/Core/IntakeGroupBadge.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeGcPlan.h"
#include "TestHarness.h"

#include <map>
#include <string>
#include <vector>

using namespace intake;

namespace {

ActionRoot actionRoot(const std::string &id, const std::string &album, IntakeStatus status = IntakeStatus::Placed) {
    ActionRoot r;
    r.id = id;
    r.rootPath = "/income/dump/Fixture Artist - " + album;
    r.albumartist = "Fixture Artist";
    r.album = album;
    r.status = status;
    r.placedVerified = status == IntakeStatus::Placed;
    r.placedTargetPath = "/library/A/" + album;
    return r;
}

PlacedRootFiles filesOf(const ActionRoot &root, size_t count, bool wholeFolder = true) {
    PlacedRootFiles f;
    f.id = root.id;
    f.rootPath = root.rootPath;
    f.targetPath = root.placedTargetPath;
    f.wholeFolder = wholeFolder;
    for (size_t i = 1; i <= count; i++) {
        SidecarFile file;
        file.path = (i < 10 ? "0" : "") + std::to_string(i) + " - Track.wav";
        file.shadow = i == count;  // the last one a shadow
        f.files.push_back(file);
    }
    return f;
}

IntakeRecord current(const std::string &id, IntakeStatus status, bool verified) {
    IntakeRecord r;
    r.id = id;
    r.status = status;
    r.hasPlaced = status == IntakeStatus::Placed || status == IntakeStatus::GcDone;
    r.placedVerified = verified;
    r.placedTargetPath = "/library/A/now";
    return r;
}

size_t countOf(const std::string &text, const std::string &needle) {
    size_t n = 0;
    for (size_t at = text.find(needle); at != std::string::npos; at = text.find(needle, at + 1)) n++;
    return n;
}

} // namespace

static void testPaths() {
    g_context = "paths";
    const ActionRoot a = actionRoot("itk_00000012", "Placed Album");
    PlacedRootFiles f = filesOf(a, 3);
    std::vector<std::string> paths = gcLocalPaths(f);
    CHECK(paths == std::vector<std::string>({a.rootPath + "/01 - Track.wav", a.rootPath + "/02 - Track.wav",
                                             a.rootPath + "/03 - Track.wav"}),
          "root_path + files[].path for every entry, the shadow included (gc removes every local copy)");
    f.rootPath += "/";
    CHECK(gcLocalPaths(f)[0] == a.rootPath + "/01 - Track.wav", "a trailing slash on root_path");

    const GcConfirmRoot known = gcConfirmRoot(a, &f, std::string());
    CHECK(known.filesKnown && known.wholeFolder && known.localPaths.size() == 3, "a root with its file list");
    const GcConfirmRoot unknown = gcConfirmRoot(a, nullptr, "cannot read x (Operation timed out)");
    CHECK(!unknown.filesKnown && unknown.localPaths.empty() && unknown.filesError == "cannot read x (Operation timed out)",
          "a root without one keeps the reason");
    CHECK(!gcConfirmRoot(a, nullptr, std::string()).filesError.empty(), "a default reason");
}

// `rows` income rows, all in the playlist Delete was opened from.
static GcIncomeRows inActive(size_t rows) {
    GcIncomeRows r;
    r.rows = rows;
    r.inFirst = rows;
    r.playlists = rows > 0 ? 1 : 0;
    return r;
}

static void testText() {
    g_context = "text";
    CHECK(gcConfirmTitle(1) == "Delete the local copy of this album?", "title, one album");
    CHECK(gcConfirmTitle(3) == "Delete the local copies of 3 albums?", "title, several");

    const ActionRoot a = actionRoot("itk_00000012", "Placed Album");
    const ActionRoot b = actionRoot("itk_00000016", "Loose");
    const PlacedRootFiles fa = filesOf(a, 8);
    const PlacedRootFiles fb = filesOf(b, 4, false);
    std::vector<GcConfirmRoot> roots = {gcConfirmRoot(a, &fa, ""), gcConfirmRoot(b, &fb, "")};
    const std::string text = gcConfirmText(roots, inActive(0));
    CHECK(countOf(text, ".wav\n") == 10 && text.find(a.rootPath + "/01 - Track.wav") == 0,
          "the paths come first, one per line, ten of them");
    CHECK(text.find(b.rootPath + "/02 - Track.wav") != std::string::npos &&
              text.find(b.rootPath + "/03 - Track.wav") == std::string::npos,
          "at most 10 paths (8 + 2), in root order");
    CHECK(text.find("\nand 2 more") != std::string::npos, "then \"and N more\" (12 paths, 10 listed)");
    CHECK(text.find("(covers, cues, logs) are deleted too") != std::string::npos, "the whole-folder note");
    CHECK(text.find("Swap, then delete") == std::string::npos, "no income rows: no mention of the swap");
    CHECK(text.find("The library copies stay.") != std::string::npos, "the library copies stay");

    const std::string withRows = gcConfirmText(roots, inActive(3));
    CHECK(withRows.find("3 rows in the active playlist still play these files. \"Swap, then delete\" points them at "
                        "the library copies first.") != std::string::npos,
          "income rows: the swap is offered in the text");
    CHECK(gcConfirmText(roots, inActive(1)).find("1 row in the active playlist still plays these files") != std::string::npos,
          "one row: singular");

    std::vector<GcConfirmRoot> exact = {gcConfirmRoot(a, &fa, "")};
    CHECK(gcConfirmText(exact, inActive(0)).find("more") == std::string::npos, "8 paths: all listed, no \"more\"");
    std::vector<GcConfirmRoot> virtualOnly = {gcConfirmRoot(b, &fb, "")};
    CHECK(gcConfirmText(virtualOnly, inActive(0)).find("covers, cues") == std::string::npos,
          "a virtual root has no artifacts: no whole-folder note");
    std::vector<GcConfirmRoot> unreadable = {gcConfirmRoot(a, nullptr, "no sidecar for itk_00000012")};
    const std::string none = gcConfirmText(unreadable, inActive(0));
    CHECK(none.find("No local file list could be read.") == 0 &&
              none.find("The file list of Fixture Artist \xE2\x80\x93 Placed Album could not be read: no sidecar for "
                        "itk_00000012.") != std::string::npos,
          "an unreadable root is named with the reason");
    CHECK(gcConfirmText(roots, inActive(0), 3).find("\nand 9 more") != std::string::npos, "the cap is a parameter");

    // Rows in other playlists too: counted and named, the swap still offered.
    GcIncomeRows spread = inActive(2);
    spread.rows = 5;
    spread.playlists = 3;
    CHECK(gcConfirmText(roots, spread).find("5 rows in 3 playlists still play these files. \"Swap, then delete\" "
                                            "points them at the library copies first.") != std::string::npos,
          "rows outside the active playlist: every playlist is counted");
    CHECK(spread.offerSwap(), "offered across playlists");

    // A row Swap never moves: the swap is not offered, the row is named.
    GcIncomeRows stuck = inActive(3);
    stuck.noLibraryCopy = 1;
    const std::string stuckText = gcConfirmText(roots, stuck);
    CHECK(!stuck.offerSwap() && stuckText.find("3 rows in the active playlist still play these files. 1 of them has "
                                               "no library copy") != std::string::npos &&
              stuckText.find("\"Swap, then delete\" points") == std::string::npos,
          "a shadow or unlisted row: named, and no swap offered (it could never end in gc)");

    // Rows whose volume could not be checked.
    GcIncomeRows unknown = inActive(2);
    unknown.unchecked = 4;
    const std::string unknownText = gcConfirmText(roots, unknown);
    CHECK(unknownText.find("4 playlist rows on a slow volume could not be checked. \"Swap, then delete\" deletes "
                           "nothing while a row is unchecked.") != std::string::npos,
          "unchecked rows are named");
    CHECK(unknown.offerSwap() && !unknown.clear() && inActive(0).clear() && !inActive(1).clear(),
          "clear only with no income row and nothing unchecked");
    GcIncomeRows onlyUnknown;
    onlyUnknown.unchecked = 1;
    CHECK(!onlyUnknown.offerSwap() && !onlyUnknown.clear() &&
              gcConfirmText(roots, onlyUnknown).find("1 playlist row on a slow volume could not be checked.") !=
                  std::string::npos,
          "unchecked rows alone: named, no swap offered, not clear");
}

static void testSummary() {
    g_context = "summary";
    const ActionRoot a = actionRoot("itk_00000012", "Placed Album");
    const PlacedRootFiles fa = filesOf(a, 2);
    std::vector<GcConfirmRoot> roots = {gcConfirmRoot(a, &fa, "")};
    CHECK(gcConfirmSummary(roots, inActive(2)) == "2 path(s): " + a.rootPath + "/01 - Track.wav | " + a.rootPath +
                                            "/02 - Track.wav; Swap, then delete offered (2 income row(s))",
          "paths, then the swap offered with the income rows");
    CHECK(gcConfirmSummary(roots, inActive(0)).find("; Swap, then delete not offered (no income row)") != std::string::npos,
          "no income row: not offered");
    const PlacedRootFiles many = filesOf(a, 5);
    std::vector<GcConfirmRoot> five = {gcConfirmRoot(a, &many, "")};
    CHECK(gcConfirmSummary(five, inActive(0)).find("5 path(s): ") == 0 &&
              gcConfirmSummary(five, inActive(0)).find(" (+2 more)") != std::string::npos,
          "three paths, then (+N more)");
    std::vector<GcConfirmRoot> mixed = {gcConfirmRoot(a, &fa, ""), gcConfirmRoot(actionRoot("itk_00000016", "X"), nullptr, "e")};
    CHECK(gcConfirmSummary(mixed, inActive(0)).find("; 1 root(s) without a file list") != std::string::npos,
          "roots without a file list are counted");
    CHECK(gcAllPaths(mixed).size() == 2, "all paths, in order");

    GcIncomeRows spread = inActive(2);
    spread.rows = 3;
    spread.playlists = 2;
    CHECK(gcConfirmSummary(roots, spread).find("; Swap, then delete offered (3 income row(s) in 2 playlist(s))") !=
              std::string::npos,
          "rows in other playlists: the playlists are counted");
    GcIncomeRows stuck = inActive(2);
    stuck.noLibraryCopy = 1;
    CHECK(gcConfirmSummary(roots, stuck).find("; Swap, then delete not offered (2 income row(s), 1 without a library "
                                              "copy)") != std::string::npos,
          "rows Swap never moves: not offered");
    GcIncomeRows unknown = inActive(2);
    unknown.unchecked = 3;
    CHECK(gcConfirmSummary(roots, unknown).find("offered (2 income row(s)); 3 row(s) not checked (slow volume)") !=
              std::string::npos,
          "unchecked rows are counted");
}

static void testRecheck() {
    g_context = "recheck";
    std::map<std::string, IntakeRecord> now = {
        {"itk_00000012", current("itk_00000012", IntakeStatus::Placed, true)},
        {"itk_00000013", current("itk_00000013", IntakeStatus::GcDone, true)},
        {"itk_00000014", current("itk_00000014", IntakeStatus::Rejected, false)},
        {"itk_00000020", current("itk_00000020", IntakeStatus::Placed, false)},
    };
    auto lookup = [&now](const std::string &id) -> const IntakeRecord * {
        auto it = now.find(id);
        return it == now.end() ? nullptr : &it->second;
    };
    std::vector<ActionRoot> captured = {actionRoot("itk_00000012", "A"), actionRoot("itk_00000013", "B"),
                                        actionRoot("itk_00000014", "C"), actionRoot("itk_00000020", "D"),
                                        actionRoot("itk_00000099", "E")};
    const GcRecheck r = recheckGcRoots(captured, lookup);
    CHECK(r.keep.size() == 1 && r.keep[0].id == "itk_00000012" && r.keep[0].placedTargetPath == "/library/A/now",
          "the root still placed and verified is kept, with the current target");
    CHECK(r.dropped.size() == 4, "the others are dropped");
    CHECK(r.dropped[0] == std::make_pair(std::string("itk_00000013"), std::string("now gc_done, not placed")),
          "gc_done meanwhile (deleted already)");
    CHECK(r.dropped[1].first == "itk_00000014" && r.dropped[1].second == "now rejected, not placed",
          "rejected is never collected");
    CHECK(r.dropped[2].first == "itk_00000020" && r.dropped[2].second == "placed.verified is no longer true",
          "placed without placed.verified");
    CHECK(r.dropped[3].first == "itk_00000099" && r.dropped[3].second == "no longer listed by intake status",
          "gone from status");
    CHECK(recheckGcRoots({}, lookup).keep.empty() && recheckGcRoots(captured, nullptr).keep.empty(),
          "nothing captured, or no lookup: nothing kept");
}

int main() {
    @autoreleasepool {
        testPaths();
        testText();
        testSummary();
        testRecheck();
    }
    TEST_MAIN_END();
}
