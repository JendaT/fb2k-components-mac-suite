//
//  IntakeExecuteFollowUpTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeExecuteFollowUp (Execute placement…'s follow-ups):
//  the two checkboxes (delete enabled only while swap is on, unticked while
//  disabled, its tick back when swap is ticked again), the recorded choice
//  (delete only with swap), the hidden settings' defaults, which roots are
//  swapped after the run (placed with placed.verified now, run order, each
//  once), which are deleted after the swap (the gc guard against the
//  current records, the census per root, unchecked rows stopping every
//  root, a refusal skipping every root, the skip reasons and tooltip
//  baselines), and the log and tooltip texts. Synthetic ids and paths only.
//
// TEST_DEPS: src/Core/IntakeGcPlan.mm src/Core/IntakeActionTable.mm src/Core/IntakeCapabilities.mm
// TEST_DEPS: src/Core/IntakeCommandArgs.mm src/Core/IntakeSemver.mm src/Core/IntakeSettingsParse.mm
// TEST_DEPS: src/Core/IntakeReviewRule.mm src/Core/IntakeStatusModel.mm src/Core/IntakeEnvelope.mm
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeLog.mm src/Core/IntakeErrorMap.mm
// TEST_DEPS: src/Core/IntakeDecorationMap.mm src/Core/IntakeGroupBadge.mm src/Core/IntakeTargetPath.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeExecuteFollowUp.h"
#include "TestHarness.h"

#include <string>
#include <unordered_map>
#include <vector>

using namespace intake;

namespace {

std::vector<std::string> v(std::initializer_list<std::string> items) {
    return std::vector<std::string>(items);
}

IntakeRecord record(const std::string &id, IntakeStatus status, bool verified = true) {
    IntakeRecord r;
    r.id = id;
    r.rootPath = "/income/dump/Fixture Artist - Album " + id.substr(id.size() - 2);
    r.albumartist = "Fixture Artist";
    r.album = "Album " + id.substr(id.size() - 2);
    r.status = status;
    r.hasPlaced = status == IntakeStatus::Placed || status == IntakeStatus::GcDone;
    r.placedVerified = r.hasPlaced && verified;
    r.placedTargetPath = r.hasPlaced ? "/library/music.hq/Test Collection A/Fixture Artist - " + r.album : "";
    return r;
}

struct Records {
    std::vector<IntakeRecord> list;
    FollowUpRecordLookup lookup() const {
        return [this](const std::string &id) -> const IntakeRecord * {
            for (const IntakeRecord &r : list) {
                if (r.id == id) return &r;
            }
            return nullptr;
        };
    }
};

std::vector<std::string> gcIds(const FollowUpGcPlan &plan) {
    std::vector<std::string> out;
    for (const ActionRoot &r : plan.gc) out.push_back(r.id);
    return out;
}

const FollowUpSkip *skipFor(const FollowUpGcPlan &plan, const std::string &id) {
    for (const FollowUpSkip &s : plan.skipped) {
        if (s.id == id) return &s;
    }
    return nullptr;
}

} // namespace

static void testCheckboxes() {
    g_context = "checkboxes";
    FollowUpCheckboxes b = followUpCheckboxes(true, false);
    CHECK(b.swapOn && b.deleteEnabled && !b.deleteOn, "the defaults: swap on, delete off and clickable");
    b = followUpCheckboxes(true, true);
    CHECK(b.swapOn && b.deleteEnabled && b.deleteOn, "both on");
    b = followUpCheckboxes(false, true);
    CHECK(!b.swapOn && !b.deleteEnabled && !b.deleteOn, "swap off: delete disabled and shown unticked");
    b = followUpCheckboxes(false, false);
    CHECK(!b.swapOn && !b.deleteEnabled && !b.deleteOn, "both off: delete disabled");
    // Untick swap, tick it again: the sheet keeps the wanted delete tick.
    const bool wanted = true;
    CHECK(!followUpCheckboxes(false, wanted).deleteOn && followUpCheckboxes(true, wanted).deleteOn,
          "the delete tick comes back with swap");

    RunFollowUps c = chosenFollowUps(true, false);
    CHECK(c.recorded && c.swap && !c.deleteLocal, "swap only");
    c = chosenFollowUps(true, true);
    CHECK(c.recorded && c.swap && c.deleteLocal, "swap, then delete");
    c = chosenFollowUps(false, true);
    CHECK(c.recorded && !c.swap && !c.deleteLocal, "delete never without swap");
    c = chosenFollowUps(false, false);
    CHECK(c.recorded && !c.swap && !c.deleteLocal, "nothing chosen, still recorded");

    CHECK(hasFollowUps(RunFollowUps{true, true, false}) && hasFollowUps(RunFollowUps{true, true, true}),
          "swap on: something to do");
    CHECK(!hasFollowUps(RunFollowUps{true, false, false}), "recorded with swap off: nothing to do");
    CHECK(!hasFollowUps(RunFollowUps{}) && !hasFollowUps(RunFollowUps{false, true, true}),
          "not recorded (an older build's run file, a resume): nothing, whatever the flags say");

    CHECK(followUpSetting(kExecuteSwapAfterDefault) && !followUpSetting(kExecuteDeleteAfterDefault),
          "defaults: swap 1, delete 0");
    CHECK(followUpSetting(1) && followUpSetting(-1) && followUpSetting(7) && !followUpSetting(0),
          "0 is off, anything else on");
}

static void testSwapRoots() {
    g_context = "swap-roots";
    Records now;
    now.list = {record("itk_00000010", IntakeStatus::Placed), record("itk_00000011", IntakeStatus::Approved),
                record("itk_00000012", IntakeStatus::Placing), record("itk_00000013", IntakeStatus::Placed, false),
                record("itk_00000014", IntakeStatus::Placed)};
    // itk_00000015: no longer listed.
    const FollowUpSwapPlan plan = planFollowUpSwap(
        v({"itk_00000014", "itk_00000010", "itk_00000011", "itk_00000012", "itk_00000013", "itk_00000015", "itk_00000014"}),
        now.lookup());
    CHECK(plan.swap == v({"itk_00000014", "itk_00000010"}), "placed and verified, run order, each once");
    CHECK_EQ(plan.notSwapped.size(), 4, "four left out");
    CHECK(plan.notSwapped.size() == 4 && plan.notSwapped[0].first == "itk_00000011" &&
              plan.notSwapped[0].second == "now approved, not placed",
          "the run did not place it (reverted or failed)");
    CHECK(plan.notSwapped.size() == 4 && plan.notSwapped[1].first == "itk_00000012" &&
              plan.notSwapped[1].second == "now placing, not placed",
          "still placing (interrupted)");
    CHECK(plan.notSwapped.size() == 4 && plan.notSwapped[2].first == "itk_00000013" &&
              plan.notSwapped[2].second == "placed.verified is not true",
          "placed but not verified: Swap never moves it");
    CHECK(plan.notSwapped.size() == 4 && plan.notSwapped[3].first == "itk_00000015" &&
              plan.notSwapped[3].second == "no longer listed by intake status",
          "gone from status");
    CHECK(planFollowUpSwap({}, now.lookup()).swap.empty(), "no ids: nothing");
    const FollowUpSwapPlan blind = planFollowUpSwap(v({"itk_00000010"}), nullptr);
    CHECK(blind.swap.empty() && blind.notSwapped.size() == 1, "no lookup: nothing swapped");
}

static void testGcRoots() {
    g_context = "gc-roots";
    Records now;
    now.list = {record("itk_00000010", IntakeStatus::Placed), record("itk_00000011", IntakeStatus::Placed),
                record("itk_00000012", IntakeStatus::GcDone), record("itk_00000013", IntakeStatus::Placed, false),
                record("itk_00000014", IntakeStatus::Placed)};
    const std::vector<std::string> swapped =
        v({"itk_00000010", "itk_00000011", "itk_00000012", "itk_00000013", "itk_00000014", "itk_00000015"});
    // After the swap: itk_00000011 still has 2 entries on its income paths;
    // itk_00000014 has 0 (an entry the census returns as zero is clear).
    std::unordered_map<std::string, size_t> left = {{"itk_00000011", 2}, {"itk_00000014", 0}};
    FollowUpGcPlan plan = planFollowUpGc(swapped, now.lookup(), left, 0, std::string());
    CHECK(gcIds(plan) == v({"itk_00000010", "itk_00000014"}), "clear and guarded: gc, swap order");
    CHECK(plan.gc.size() == 2 && plan.gc[0].status == IntakeStatus::Placed && plan.gc[0].placedVerified &&
              plan.gc[0].placedTargetPath == now.list[0].placedTargetPath,
          "the gc root carries placed.target_path (gc's E_VERIFY names it)");
    CHECK_EQ(plan.skipped.size(), 4, "four kept");
    const FollowUpSkip *rows = skipFor(plan, "itk_00000011");
    CHECK(rows && rows->why == "2 playlist rows still point at its income paths after the swap" &&
              rows->baseline == IntakeStatus::Placed,
          "rows the swap left (no library copy): kept, baseline placed");
    const FollowUpSkip *done = skipFor(plan, "itk_00000012");
    CHECK(done && done->why == "now gc_done, not placed" && done->baseline == IntakeStatus::GcDone,
          "collected meanwhile: the guard");
    const FollowUpSkip *unverified = skipFor(plan, "itk_00000013");
    CHECK(unverified && unverified->why == "placed.verified is no longer true", "unverified: the guard");
    const FollowUpSkip *gone = skipFor(plan, "itk_00000015");
    CHECK(gone && gone->why == "no longer listed by intake status" && gone->baseline == IntakeStatus::Unknown,
          "gone: the guard, no baseline");

    left = {{"itk_00000011", 1}};
    plan = planFollowUpGc(v({"itk_00000011"}), now.lookup(), left, 0, std::string());
    CHECK(plan.gc.empty() && plan.skipped.size() == 1 &&
              plan.skipped[0].why == "1 playlist row still points at its income paths after the swap",
          "one row (the count's own wording)");

    // Unchecked entries cannot be attributed to a root: every guarded root
    // is kept; the guard's reasons come first.
    plan = planFollowUpGc(swapped, now.lookup(), {}, 3, std::string());
    CHECK(plan.gc.empty() && plan.skipped.size() == 6, "unchecked rows: nothing deleted");
    CHECK(skipFor(plan, "itk_00000010") &&
              skipFor(plan, "itk_00000010")->why == "3 playlist rows on a slow volume could not be checked",
          "a clear root is kept for the unchecked rows");
    CHECK(skipFor(plan, "itk_00000012") && skipFor(plan, "itk_00000012")->why == "now gc_done, not placed",
          "the guard's reason first");

    // A census that could not run: every root, that reason.
    plan = planFollowUpGc(swapped, now.lookup(), {}, 0, "another intake command is still running");
    CHECK(plan.gc.empty() && plan.skipped.size() == 6, "a refusal: nothing deleted");
    bool all = true;
    for (const FollowUpSkip &s : plan.skipped) all = all && s.why == "another intake command is still running";
    CHECK(all, "every root gets the refusal");
    CHECK(skipFor(plan, "itk_00000010") && skipFor(plan, "itk_00000010")->baseline == IntakeStatus::Placed,
          "with its status now as the baseline");

    plan = planFollowUpGc(v({"itk_00000010", "itk_00000010", ""}), now.lookup(), {}, 0, std::string());
    CHECK(gcIds(plan) == v({"itk_00000010"}) && plan.skipped.empty(), "repeats and empty ids dropped");
    CHECK(planFollowUpGc({}, now.lookup(), {}, 5, "x").gc.empty() &&
              planFollowUpGc({}, now.lookup(), {}, 5, "x").skipped.empty(),
          "no roots: nothing");
    plan = planFollowUpGc(v({"itk_00000010"}), nullptr, {}, 0, std::string());
    CHECK(plan.gc.empty() && plan.skipped.size() == 1 && plan.skipped[0].why == "no longer listed by intake status",
          "no lookup: nothing deleted");
}

static void testTexts() {
    g_context = "texts";
    FollowUpSkip skip;
    skip.id = "itk_00000011";
    skip.why = "2 playlist rows still point at its income paths after the swap";
    CHECK(followUpSkipLine("execute-20261121-101500-123", skip) ==
              "delete-local: itk_00000011: local copy kept after run execute-20261121-101500-123: 2 playlist rows "
              "still point at its income paths after the swap",
          "the Info line names the root and the run");
    CHECK(followUpSkipTooltip(skip) ==
              "delete-local: local copy kept: 2 playlist rows still point at its income paths after the swap",
          "the tooltip, in the per-command error form");
    CHECK(earlierRunFollowUpLine("execute-a", RunFollowUps{true, true, false}) ==
              "run execute-a: swap/delete as chosen at its start (swap only)",
          "an earlier session's run: swap only");
    CHECK(earlierRunFollowUpLine("execute-a", RunFollowUps{true, true, true}) ==
              "run execute-a: swap/delete as chosen at its start (swap, then delete)",
          "an earlier session's run: swap, then delete");
}

int main() {
    @autoreleasepool {
        testCheckboxes();
        testSwapRoots();
        testGcRoots();
        testTexts();
    }
    TEST_MAIN_END();
}
