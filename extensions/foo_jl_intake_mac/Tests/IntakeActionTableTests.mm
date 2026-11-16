//
//  IntakeActionTableTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeActionTable: the doc 04 v1.2 enable rule for every
//  action and status, the table rules (no CLI path, Refresh, inert, empty
//  selections, mixed selections and "(n of m)", Reject feature detection,
//  the busy lane and "(execute running)", the ellipsis last and only when
//  a dialog follows), quick-assign alternates, the
//  argv each action builds (through IntakeCommandArgs, never with zero ids),
//  album labels for the Reject confirmation, and action_id encoding.
//  B7: the exposed set, quick assign (order, dedup, cap 4, target excluded,
//  absent or empty ranked, status gating, one root only, none for an
//  incomplete selection), "Assign to other
//  collection…" first when amber, its "(n of m)" on mixed selections, and
//  the assign argv of both entries.
//  Synthetic records only.
//
// TEST_DEPS: src/Core/IntakeCapabilities.mm src/Core/IntakeCommandArgs.mm src/Core/IntakeSemver.mm
// TEST_DEPS: src/Core/IntakeSettingsParse.mm src/Core/IntakeReviewRule.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeActionTable.h"
#include "TestHarness.h"

#include <algorithm>
#include <string>
#include <unistd.h>
#include <vector>

using namespace intake;

namespace {

const std::string kEllipsis = "\xE2\x80\xA6";
const std::string kReject = "Reject" + kEllipsis;

CliVersionInfo cli030() {
    CliVersionInfo info;
    info.cli = "0.3.0";
    info.hasCommands = true;
    info.commands = {"version", "status", "collections", "income", "propose", "assign",
                     "approve", "reject",  "execute",     "gc"};
    return info;
}

CliVersionInfo cliOld(const char *version) {
    CliVersionInfo info;
    info.cli = version;
    return info;
}

ActionContext ctx(CliVersionInfo info = cli030()) {
    ActionContext c;
    c.cliConfigured = true;
    c.cli = std::move(info);
    return c;
}

IntakeRecord rec(const char *id, IntakeStatus status) {
    IntakeRecord r;
    r.id = id;
    r.rootPath = r.rootKey = std::string("/income/dump/Fixture Artist - Album ") + id;
    r.status = status;
    r.albumartist = "Fixture Artist";
    r.album = std::string("Album ") + id;
    return r;
}

IntakeRecord withProposal(IntakeRecord r, TargetPathState target = TargetPathState::Set) {
    r.hasProposal = true;
    r.proposal.targetCollection = "Test Collection A";
    r.proposal.confidence = 0.8;
    r.proposal.hasConfidence = true;
    r.proposal.assignedBy = AssignedBy::Engine;
    r.proposal.targetPathState = target;
    if (target == TargetPathState::Set) r.proposal.targetPath = "/library/Test Collection A/x";
    for (const char *name : {"Test Collection A", "Test Collection B", "Test Collection C", "Test & Ambient",
                             "Fixture Downtempo", "Test Collection B"}) {
        RankedCandidate c;
        c.collection = name;
        r.proposal.ranked.push_back(c);
    }
    r.proposal.rankedState = RankedState::Present;
    return r;
}

std::vector<std::string> ids(const ActionEntry &e) {
    std::vector<std::string> out;
    for (const ActionRoot &r : e.roots) out.push_back(r.id);
    return out;
}

std::vector<std::string> titles(const ActionTable &t) {
    std::vector<std::string> out;
    for (const ActionEntry &e : t.entries) out.push_back(e.title);
    return out;
}

std::vector<std::string> v(std::initializer_list<std::string> items) {
    return std::vector<std::string>(items);
}

const std::string kCli = "/opt/intake/bin/intake";
std::string g_emptyDir;

CliConfig cliConfig() {
    CliConfig c;
    c.cliPath = kCli;
    c.bunSearchDirs = {g_emptyDir};
    c.baseEnvironment = std::vector<std::string>{"HOME=/Users/test", "PATH=/usr/bin:/bin"};
    c.cliVersion = "0.3.0";
    c.cliListsCommands = true;
    return c;
}

std::vector<std::string> argvFor(const ActionEntry &e, const std::string &reason = std::string()) {
    CliRequest request;
    if (!requestForEntry(e, reason, request)) return {"<no request>"};
    CliInvocation inv = buildInvocation(cliConfig(), request);
    if (inv.status != BuildStatus::Ok) return {"<" + inv.message + ">"};
    return inv.arguments;
}

} // namespace

static void testEnableMatrix() {
    g_context = "enable-matrix";
    const IntakeStatus statuses[] = {IntakeStatus::New,    IntakeStatus::Resolved, IntakeStatus::Proposed,
                                     IntakeStatus::Approved, IntakeStatus::Placing,  IntakeStatus::Placed,
                                     IntakeStatus::GcDone, IntakeStatus::Rejected, IntakeStatus::Unknown};
    const char *names[] = {"new", "resolved", "proposed", "approved", "placing",
                           "placed", "gc_done", "rejected", "unknown"};
    struct Row {
        IntakeAction action;
        bool expected[9];  // in `statuses` order
    };
    // A record with a target, ranked alternates and placed.verified; CLI 0.3.0.
    const Row rows[] = {
        {IntakeAction::Propose, {false, true, false, false, false, false, false, false, false}},
        {IntakeAction::AssignTo, {true, true, true, true, false, false, false, false, false}},
        {IntakeAction::AssignOther, {true, true, true, true, false, false, false, false, false}},
        {IntakeAction::Approve, {false, false, true, false, false, false, false, false, false}},
        {IntakeAction::Reject, {true, true, true, true, false, false, false, false, false}},
        {IntakeAction::Execute, {false, false, false, true, false, false, false, false, false}},
        {IntakeAction::Resume, {false, false, false, false, true, false, false, false, false}},
        {IntakeAction::Swap, {false, false, false, false, false, true, false, false, false}},
        {IntakeAction::DeleteLocal, {false, false, false, false, false, true, false, false, false}},
        {IntakeAction::Refresh, {true, true, true, true, true, true, true, true, true}},
    };
    const ActionContext c = ctx();
    for (const Row &row : rows) {
        for (size_t i = 0; i < 9; i++) {
            IntakeRecord r = withProposal(rec("itk_00000001", statuses[i]));
            r.hasPlaced = true;
            r.placedVerified = true;
            const std::string what = std::string(actionName(row.action)) + " on " + names[i];
            CHECK(rootQualifies(row.action, r, c) == row.expected[i], what.c_str());
        }
    }
}

static void testEnableConditions() {
    g_context = "enable-conditions";
    const ActionContext c = ctx();
    IntakeRecord slot = withProposal(rec("itk_00000001", IntakeStatus::Proposed), TargetPathState::Null);
    CHECK(!rootQualifies(IntakeAction::Approve, slot, c), "Approve: null target_path refused");
    IntakeRecord unknown = withProposal(rec("itk_00000001", IntakeStatus::Proposed), TargetPathState::Unknown);
    CHECK(rootQualifies(IntakeAction::Approve, unknown, c), "Approve: unknown target_path (CLI 0.2.1) allowed");
    IntakeRecord noProposal = rec("itk_00000001", IntakeStatus::Proposed);
    CHECK(rootQualifies(IntakeAction::Approve, noProposal, c), "Approve: no proposal is not a null target");
    IntakeRecord approvedSlot = withProposal(rec("itk_00000001", IntakeStatus::Approved), TargetPathState::Null);
    CHECK(!rootQualifies(IntakeAction::Execute, approvedSlot, c), "Execute: null target_path refused");

    IntakeRecord resolved = rec("itk_00000001", IntakeStatus::Resolved);
    CHECK(!rootQualifies(IntakeAction::Reject, resolved, ctx(cliOld("0.1.0"))), "Reject: not on CLI 0.1.0");
    CHECK(rootQualifies(IntakeAction::Reject, resolved, ctx(cliOld("0.2.0"))), "Reject: from CLI 0.2.0 by semver");
    CliVersionInfo listedNoReject = cli030();
    listedNoReject.commands = {"version", "status", "propose"};
    CHECK(!rootQualifies(IntakeAction::Reject, resolved, ctx(listedNoReject)), "Reject: commands[] decides");

    IntakeRecord placing = rec("itk_00000011", IntakeStatus::Placing);
    CHECK(!rootQualifies(IntakeAction::Resume, placing, ctx(cliOld("0.2.0"))), "Resume: not before 0.2.1");
    CHECK(rootQualifies(IntakeAction::Resume, placing, ctx(cliOld("0.2.1"))), "Resume: 0.2.1");
    ActionContext live = ctx();
    live.liveRunIds = {"itk_00000011"};
    CHECK(!rootQualifies(IntakeAction::Resume, placing, live), "Resume: not while a live run holds the root");

    IntakeRecord unverified = rec("itk_00000012", IntakeStatus::Placed);
    unverified.hasPlaced = true;
    unverified.placedVerified = false;
    CHECK(!rootQualifies(IntakeAction::Swap, unverified, c), "Swap: placed.verified required");
    CHECK(!rootQualifies(IntakeAction::DeleteLocal, unverified, c), "Delete: placed.verified required");

    IntakeRecord noRanked = rec("itk_00000001", IntakeStatus::Proposed);
    noRanked.hasProposal = true;
    noRanked.proposal.targetCollection = "Test Collection A";
    noRanked.proposal.rankedState = RankedState::Absent;
    CHECK(!rootQualifies(IntakeAction::AssignTo, noRanked, c), "Assign to X: needs ranked");
    CHECK(rootQualifies(IntakeAction::AssignOther, noRanked, c), "Assign other: no ranked needed");
}

static void testAlternates() {
    g_context = "alternates";
    IntakeRecord r = withProposal(rec("itk_00000001", IntakeStatus::Proposed));
    CHECK(assignAlternates(r) == v({"Test Collection B", "Test Collection C", "Test & Ambient", "Fixture Downtempo"}),
          "ranked minus the target, at most 4, in order");
    CHECK(assignAlternates(r, 2) == v({"Test Collection B", "Test Collection C"}), "limit");
    IntakeRecord dup = r;
    dup.proposal.ranked.erase(dup.proposal.ranked.begin() + 2, dup.proposal.ranked.begin() + 5);
    CHECK(assignAlternates(dup) == v({"Test Collection B"}), "a repeated name is listed once");
    IntakeRecord empty = r;
    empty.proposal.ranked.clear();
    empty.proposal.rankedState = RankedState::Empty;
    CHECK(assignAlternates(empty).empty(), "ranked [] gives none");
}

static void testTableRules() {
    g_context = "table";
    IntakeRecord resolved = rec("itk_0000000b", IntakeStatus::Resolved);
    std::vector<const IntakeRecord *> one = {&resolved};

    ActionContext off = ctx();
    off.cliConfigured = false;
    CHECK(buildActionTable(one, off, b6Actions()).entries.empty(), "no CLI path: no items");

    ActionTable none = buildActionTable({}, ctx(), b6Actions());
    CHECK(titles(none) == v({"Refresh intake status"}), "no intake root selected: Refresh only");
    CHECK(none.entries[0].enabled && none.entries[0].action == IntakeAction::Refresh, "Refresh is enabled");

    ActionContext inert = ctx();
    inert.inert = true;
    CHECK(titles(buildActionTable(one, inert, b6Actions())) == v({"Refresh intake status"}), "inert: Refresh only");

    ActionTable t = buildActionTable(one, ctx(), b6Actions());
    CHECK(titles(t) == v({"Propose", "Approve", kReject, "Refresh intake status"}), "B6 items, fixed order");
    CHECK(t.entries[0].enabled && ids(t.entries[0]) == v({"itk_0000000b"}), "Propose enabled on resolved");
    CHECK(!t.entries[1].enabled && t.entries[1].roots.empty(), "Approve disabled, no roots");
    CHECK(t.entries[2].enabled, "Reject enabled on resolved");
    CHECK(t.selectedRoots == 1, "m = 1");

    ActionContext noConfirm = ctx();
    noConfirm.confirmReject = false;
    CHECK(buildActionTable(one, noConfirm, b6Actions()).entries[2].title == "Reject",
          "confirm_reject off: Reject runs at once, no ellipsis");
    IntakeRecord placedMix = rec("itk_00000012", IntakeStatus::Placed);
    CHECK(buildActionTable({&resolved, &placedMix}, noConfirm, b6Actions()).entries[2].title == "Reject (1 of 2)",
          "confirm_reject off, mixed: no ellipsis either");
    CHECK(actionAsksFirst(IntakeAction::Execute, noConfirm) && actionAsksFirst(IntakeAction::AssignOther, noConfirm) &&
              !actionAsksFirst(IntakeAction::Propose, ctx()) && !actionAsksFirst(IntakeAction::Refresh, ctx()),
          "execute and the picker always ask; propose and refresh never");

    ActionTable old = buildActionTable(one, ctx(cliOld("0.1.0")), b6Actions());
    CHECK(titles(old) == v({"Propose", "Approve", "Refresh intake status"}), "CLI 0.1.0: Reject is not listed");

    IntakeRecord placed = rec("itk_00000012", IntakeStatus::Placed);
    placed.hasPlaced = placed.placedVerified = true;
    ActionTable p = buildActionTable({&placed}, ctx(), b6Actions());
    CHECK(titles(p) == v({"Propose", "Approve", kReject, "Refresh intake status"}), "a placed root lists the same items");
    CHECK(!p.entries[0].enabled && !p.entries[1].enabled && !p.entries[2].enabled, "all disabled on placed");
}

static void testMixed() {
    g_context = "mixed";
    IntakeRecord n = rec("itk_0000000a", IntakeStatus::New);
    IntakeRecord r = rec("itk_0000000b", IntakeStatus::Resolved);
    IntakeRecord p = withProposal(rec("itk_0000000d", IntakeStatus::Proposed));
    IntakeRecord slot = withProposal(rec("itk_00000019", IntakeStatus::Proposed), TargetPathState::Null);
    IntakeRecord placed = rec("itk_00000012", IntakeStatus::Placed);

    ActionTable t = buildActionTable({&n, &r, &p, &slot, &placed}, ctx(), b6Actions());
    CHECK(t.selectedRoots == 5, "m counts every selected root");
    CHECK(titles(t) == v({"Propose (1 of 5)", "Approve (1 of 5)", "Reject (4 of 5)" + kEllipsis, "Refresh intake status"}),
          "(n of m) on a mixed selection, the ellipsis last");
    CHECK(ids(t.entries[0]) == v({"itk_0000000b"}), "Propose runs on the resolved root only");
    CHECK(ids(t.entries[1]) == v({"itk_0000000d"}), "Approve skips the slot-pending root");
    CHECK(ids(t.entries[2]) == v({"itk_0000000a", "itk_0000000b", "itk_0000000d", "itk_00000019"}),
          "Reject runs on its four roots, selection order");

    IntakeRecord p2 = withProposal(rec("itk_0000000e", IntakeStatus::Proposed));
    ActionTable all = buildActionTable({&p, &p2}, ctx(), b6Actions());
    CHECK(all.entries[1].title == "Approve", "every root qualifies: no (n of m)");
    CHECK(ids(all.entries[1]) == v({"itk_0000000d", "itk_0000000e"}), "Approve over a multi-selection is the batch");
    CHECK(!all.entries[0].enabled && all.entries[0].title == "Propose", "none qualifies: disabled, no (0 of m)");

    std::vector<const IntakeRecord *> rows = {nullptr, &p, &r, &p, nullptr, &r};
    std::vector<const IntakeRecord *> roots = selectionRoots(rows);
    CHECK(roots.size() == 2 && roots[0] == &p && roots[1] == &r, "selection roots: deduplicated, ordered, unmapped skipped");
    IntakeRecord pCopy = p;
    CHECK(selectionRoots({&p, &pCopy}).size() == 1, "deduplicated by id");
}

static void testLane() {
    g_context = "lane";
    IntakeRecord r = rec("itk_0000000b", IntakeStatus::Resolved);
    ActionContext busy = ctx();
    busy.laneBusy = true;
    ActionTable t = buildActionTable({&r}, busy, b6Actions());
    CHECK(!t.entries[0].enabled && !t.entries[2].enabled, "busy lane: mutating items disabled");
    CHECK(t.entries[0].title == "Propose" && ids(t.entries[0]) == v({"itk_0000000b"}),
          "busy: same title, roots still captured");
    CHECK(t.entries.back().enabled, "busy lane: Refresh stays enabled");

    busy.executeRunning = true;
    ActionTable e = buildActionTable({&r}, busy, b6Actions());
    CHECK(e.entries[0].title == "Propose (execute running)", "execute holds the lane: said so");
    CHECK(e.entries[2].title == "Reject (execute running)" + kEllipsis, "on every mutating item, the ellipsis last");
    CHECK(e.entries.back().title == "Refresh intake status", "not on Refresh");
}

static void testAllActionsExposed() {
    g_context = "all-actions";
    std::vector<IntakeAction> everything = {IntakeAction::Refresh,     IntakeAction::DeleteLocal, IntakeAction::Swap,
                                            IntakeAction::Resume,      IntakeAction::Execute,     IntakeAction::Reject,
                                            IntakeAction::Approve,     IntakeAction::AssignOther, IntakeAction::AssignTo,
                                            IntakeAction::Propose};
    IntakeRecord p = withProposal(rec("itk_0000000d", IntakeStatus::Proposed));
    ActionTable t = buildActionTable({&p}, ctx(), everything);
    CHECK(titles(t) == v({"Propose", "Assign to Test Collection B", "Assign to Test Collection C",
                          "Assign to Test & Ambient", "Assign to Fixture Downtempo",
                          "Assign to other collection" + kEllipsis, "Approve", kReject,
                          "Execute placement" + kEllipsis, "Resume placement", "Swap to library paths",
                          "Delete local copy" + kEllipsis, "Refresh intake status"}),
          "the full table order, quick assign for one root");
    CHECK(t.entries[1].collection == "Test Collection B" && t.entries[1].enabled, "quick assign carries its collection");

    IntakeRecord p2 = withProposal(rec("itk_0000000e", IntakeStatus::Proposed));
    ActionTable two = buildActionTable({&p, &p2}, ctx(), everything);
    CHECK(findEntry(two, IntakeAction::AssignTo) == nullptr, "quick assign only for one selected root");
    CHECK(findEntry(two, IntakeAction::AssignOther) != nullptr, "assign other for several");
}

static void testArgv() {
    g_context = "argv";
    IntakeRecord r = rec("itk_0000000b", IntakeStatus::Resolved);
    IntakeRecord p = withProposal(rec("itk_0000000d", IntakeStatus::Proposed));
    IntakeRecord p2 = withProposal(rec("itk_0000000e", IntakeStatus::Proposed));
    ActionTable t = buildActionTable({&r, &p, &p2}, ctx());

    CHECK(argvFor(*findEntry(t, IntakeAction::Propose)) == v({kCli, "propose", "itk_0000000b", "--json"}),
          "propose <qualifying ids> --json");
    CHECK(argvFor(*findEntry(t, IntakeAction::Approve)) ==
              v({kCli, "approve", "itk_0000000d", "itk_0000000e", "--json"}),
          "approve over the qualifying roots, no --batch");
    CHECK(argvFor(*findEntry(t, IntakeAction::Reject), "wrong genre & re-tag") ==
              v({kCli, "reject", "itk_0000000b", "itk_0000000d", "itk_0000000e", "--reason", "wrong genre & re-tag",
                 "--json"}),
          "reject with a reason, passed literally");
    CHECK(argvFor(*findEntry(t, IntakeAction::Reject)) ==
              v({kCli, "reject", "itk_0000000b", "itk_0000000d", "itk_0000000e", "--json"}),
          "reject without a reason: no --reason");

    CliRequest req;
    std::string why;
    CHECK(!requestForEntry(*findEntry(t, IntakeAction::Refresh), "", req, &why) && why == "not a CLI command",
          "Refresh is not a CLI call");
    ActionEntry disabled = *findEntry(t, IntakeAction::Propose);
    disabled.enabled = false;
    CHECK(!requestForEntry(disabled, "", req, &why) && why == "disabled", "a disabled entry runs nothing");
    ActionEntry emptyRoots = *findEntry(t, IntakeAction::Approve);
    emptyRoots.roots.clear();
    CHECK(!requestForEntry(emptyRoots, "", req, &why) && why == "no qualifying root",
          "zero ids: nothing runs (risk 3a)");
    ActionEntry repeated = *findEntry(t, IntakeAction::Approve);
    repeated.roots.push_back(repeated.roots.front());
    CHECK(requestForEntry(repeated, "", req) && req.ids == v({"itk_0000000d", "itk_0000000e"}), "ids passed once");
    CHECK(requestForEntry(*findEntry(t, IntakeAction::Propose), "ignored", req) && req.reason.empty(),
          "only reject takes the reason");

    std::vector<IntakeAction> withAssign = {IntakeAction::AssignTo};
    ActionTable qa = buildActionTable({&p}, ctx(), withAssign);
    CHECK(argvFor(qa.entries[0]) ==
              v({kCli, "assign", "itk_0000000d", "--collection", "Test Collection B", "--by", "user", "--json"}),
          "assign <id> --collection X --by user");
}

// --- B7: Assign to X and Assign to other collection… ---

// A proposal with `ranked` in this order and `target` as the target.
static IntakeRecord withRanked(IntakeRecord r, const char *target, std::initializer_list<const char *> ranked,
                        bool user = false) {
    r.hasProposal = true;
    r.proposal.targetCollection = target;
    r.proposal.confidence = user ? 1.0 : 0.61;
    r.proposal.hasConfidence = true;
    r.proposal.assignedBy = user ? AssignedBy::User : AssignedBy::Engine;
    r.proposal.targetPathState = TargetPathState::Set;
    r.proposal.targetPath = std::string("/library/") + target + "/x";
    r.proposal.ranked.clear();
    for (const char *name : ranked) {
        RankedCandidate c;
        c.collection = name;
        r.proposal.ranked.push_back(c);
    }
    r.proposal.rankedState = r.proposal.ranked.empty() ? RankedState::Empty : RankedState::Present;
    return r;
}

const std::string kOther = "Assign to other collection" + kEllipsis;

static void testMenuActions() {
    g_context = "menu-actions";
    const std::vector<IntakeAction> &m = menuActions();
    auto has = [&m](IntakeAction a) { return std::find(m.begin(), m.end(), a) != m.end(); };
    CHECK(has(IntakeAction::Propose) && has(IntakeAction::Approve) && has(IntakeAction::Reject) &&
              has(IntakeAction::Refresh),
          "B6 actions stay");
    CHECK(has(IntakeAction::AssignTo) && has(IntakeAction::AssignOther), "B7 exposes both assign entries");
    CHECK(has(IntakeAction::Execute) && has(IntakeAction::Resume), "B8 exposes Execute and Resume");
    CHECK(has(IntakeAction::Swap) && has(IntakeAction::DeleteLocal), "B9 exposes Swap and Delete local copy");
    CHECK(b6Actions().size() == 4, "the B6 subset is unchanged");
}

// --- B8: Execute placement… and Resume placement ---

const std::string kExecute = "Execute placement" + kEllipsis;
// B9: listed for every selection (disabled unless a root is placed with
// placed.verified); Delete asks first while confirm_gc is on.
const std::string kSwap = "Swap to library paths";
const std::string kDelete = "Delete local copy" + kEllipsis;

static void testExecuteResume() {
    g_context = "execute-resume";
    IntakeRecord approved = withProposal(rec("itk_00000010", IntakeStatus::Approved));
    IntakeRecord placing = withProposal(rec("itk_00000011", IntakeStatus::Placing));
    IntakeRecord slot = withProposal(rec("itk_00000019", IntakeStatus::Approved), TargetPathState::Null);
    IntakeRecord proposed = withProposal(rec("itk_0000000d", IntakeStatus::Proposed));

    ActionTable one = buildActionTable({&approved}, ctx());
    const ActionEntry *e = findEntry(one, IntakeAction::Execute);
    CHECK(e != nullptr && e->enabled && e->title == kExecute && ids(*e) == v({"itk_00000010"}),
          "Execute placement… on an approved root with a target: enabled, the ellipsis (always asks)");
    const ActionEntry *resumeOnApproved = findEntry(one, IntakeAction::Resume);
    CHECK(resumeOnApproved != nullptr && !resumeOnApproved->enabled && resumeOnApproved->title == "Resume placement",
          "Resume listed but disabled on an approved root; no ellipsis");

    ActionTable mixed = buildActionTable({&approved, &slot, &proposed}, ctx());
    e = findEntry(mixed, IntakeAction::Execute);
    CHECK(e != nullptr && e->enabled && e->title == "Execute placement (1 of 3)" + kEllipsis &&
              ids(*e) == v({"itk_00000010"}),
          "mixed: (n of m) before the ellipsis, the slot-pending root left out");

    ActionTable slotOnly = buildActionTable({&slot}, ctx());
    CHECK(!findEntry(slotOnly, IntakeAction::Execute)->enabled, "a null target_path: Execute disabled");

    ActionTable resume = buildActionTable({&placing, &approved}, ctx());
    const ActionEntry *r = findEntry(resume, IntakeAction::Resume);
    CHECK(r != nullptr && r->enabled && r->title == "Resume placement (1 of 2)" && ids(*r) == v({"itk_00000011"}),
          "Resume placement on the placing root, (n of m), no ellipsis");
    CHECK(findEntry(resume, IntakeAction::Execute)->title == "Execute placement (1 of 2)" + kEllipsis,
          "Execute on the approved root of the same selection");

    // Hidden like Reject when the CLI cannot resume by id.
    ActionTable old = buildActionTable({&placing}, ctx(cliOld("0.2.0")));
    CHECK(findEntry(old, IntakeAction::Resume) == nullptr, "CLI 0.2.0: Resume is not listed");
    CHECK(findEntry(buildActionTable({&placing}, ctx(cliOld("0.1.0"))), IntakeAction::Resume) == nullptr,
          "CLI 0.1.0: Resume is not listed");
    CHECK(findEntry(buildActionTable({&placing}, ctx(CliVersionInfo())), IntakeAction::Resume) == nullptr,
          "CLI version unknown: Resume is not listed");
    const ActionTable t021 = buildActionTable({&placing}, ctx(cliOld("0.2.1")));
    const ActionEntry *r021 = findEntry(t021, IntakeAction::Resume);
    CHECK(r021 != nullptr && r021->enabled, "CLI 0.2.1: Resume listed and enabled");
    CHECK(findEntry(old, IntakeAction::Execute) != nullptr, "Execute does not depend on the CLI version");

    // A live run on the root (adopted, or own): Resume stays disabled.
    ActionContext live = ctx();
    live.liveRunIds = {"itk_00000011"};
    const ActionTable liveTable = buildActionTable({&placing}, live);
    const ActionEntry *liveResume = findEntry(liveTable, IntakeAction::Resume);
    CHECK(liveResume != nullptr && !liveResume->enabled && liveResume->roots.empty(),
          "Resume disabled for a root in a live run");

    // While an execute or resume holds the lane: every mutating item
    // disabled and titled "(execute running)"; Refresh stays enabled.
    ActionContext running = ctx();
    running.laneBusy = true;
    running.executeRunning = true;
    running.liveRunIds = {"itk_00000010"};
    ActionTable busy = buildActionTable({&approved, &placing, &proposed}, running);
    bool allDisabled = true, allLabelled = true;
    for (const ActionEntry &entry : busy.entries) {
        // Refresh, and Swap (B9: a playlist operation, no CLI call).
        if (entry.action == IntakeAction::Refresh || entry.action == IntakeAction::Swap) continue;
        allDisabled = allDisabled && !entry.enabled;
        allLabelled = allLabelled && entry.title.find(" (execute running)") != std::string::npos;
    }
    CHECK(allDisabled && allLabelled, "every mutating item disabled, \"(execute running)\" in each title");
    CHECK(findEntry(busy, IntakeAction::Execute)->title == "Execute placement (1 of 3) (execute running)" + kEllipsis,
          "Execute: (n of m), (execute running), then the ellipsis");
    CHECK(findEntry(busy, IntakeAction::Resume)->title == "Resume placement (1 of 3) (execute running)",
          "Resume: (execute running), no ellipsis");
    CHECK(busy.entries.back().action == IntakeAction::Refresh && busy.entries.back().enabled &&
              busy.entries.back().title == "Refresh intake status",
          "Refresh stays enabled, unlabelled");

    // A dry run holds the lane: disabled, but not "(execute running)".
    ActionContext dry = ctx();
    dry.laneBusy = true;
    ActionTable dryBusy = buildActionTable({&approved}, dry);
    CHECK(!findEntry(dryBusy, IntakeAction::Execute)->enabled && findEntry(dryBusy, IntakeAction::Execute)->title == kExecute,
          "another holder: disabled, no execute label");

    // The argv: the real call, and the per-root resume.
    CHECK(argvFor(*findEntry(one, IntakeAction::Execute)) == v({kCli, "execute", "itk_00000010", "--json"}),
          "execute <ids> --json (the dry run adds --dry-run)");
    CHECK(argvFor(*r) == v({kCli, "execute", "itk_00000011", "--resume", "--json"}), "execute <ids> --resume --json");
}

static void testQuickAssign() {
    g_context = "quick-assign";
    // itk_0000000d: proposed, engine, ranked [A, B, C], target A, no review.
    IntakeRecord d = withRanked(rec("itk_0000000d", IntakeStatus::Proposed), "Test Collection A",
                                {"Test Collection A", "Test Collection B", "Test Collection C"});
    ActionTable t = buildActionTable({&d}, ctx());
    CHECK(titles(t) == v({"Propose", "Assign to Test Collection B", "Assign to Test Collection C", kOther, "Approve",
                          kReject, kExecute, "Resume placement", kSwap, kDelete, "Refresh intake status"}),
          "default menu: quick assign after Propose, the picker after it, kOrder");
    CHECK(!t.entries[0].enabled && t.entries[1].enabled && t.entries[2].enabled && t.entries[3].enabled,
          "Propose disabled; both quick entries and the picker enabled");
    CHECK(t.entries[1].collection == "Test Collection B" && t.entries[2].collection == "Test Collection C",
          "each quick entry carries its collection");
    CHECK(ids(t.entries[1]) == v({"itk_0000000d"}) && t.entries[1].roots[0].status == IntakeStatus::Proposed,
          "quick entry captures the root and its status");
    CHECK(t.entries[1].title.find(kEllipsis) == std::string::npos, "quick assign runs at once: no ellipsis");

    // Target in the middle of ranked (a user assignment keeps engine order).
    IntakeRecord f = withRanked(rec("itk_0000000f", IntakeStatus::Proposed), "Test Collection B",
                                {"Test Collection C", "Test Collection B", "Test Collection A"}, true);
    CHECK(assignAlternates(f) == v({"Test Collection C", "Test Collection A"}),
          "target excluded wherever it sits; engine order kept");
    // Target absent from ranked (user's own choice): every ranked entry.
    IntakeRecord own = withRanked(rec("itk_0000000e", IntakeStatus::Proposed), "Test & Ambient",
                                  {"Test Collection B", "Test Collection A"}, true);
    CHECK(assignAlternates(own) == v({"Test Collection B", "Test Collection A"}), "target not ranked: all of ranked");

    // Cap 4, dedup, empty names skipped.
    IntakeRecord many = withRanked(rec("itk_00000001", IntakeStatus::Resolved), "Test Collection A",
                                   {"Test Collection A", "", "Test Collection B", "Test Collection B",
                                    "Test Collection C", "Test & Ambient", "Fixture Downtempo", "Fixture Extra"});
    CHECK(assignAlternates(many) == v({"Test Collection B", "Test Collection C", "Test & Ambient", "Fixture Downtempo"}),
          "deduplicated, empty skipped, capped at 4");
    ActionTable capped = buildActionTable({&many}, ctx());
    size_t quick = 0;
    for (const ActionEntry &e : capped.entries) quick += e.action == IntakeAction::AssignTo;
    CHECK(quick == kMaxAssignAlternates && kMaxAssignAlternates == 4, "at most 4 quick entries");

    // No ranked, empty ranked, ranked holding only the target: no quick entry.
    IntakeRecord absent = withRanked(rec("itk_00000002", IntakeStatus::Proposed), "Test Collection A", {});
    absent.proposal.rankedState = RankedState::Absent;
    IntakeRecord empty = withRanked(rec("itk_00000018", IntakeStatus::Proposed), "Test Collection C", {}, true);
    IntakeRecord onlyTarget =
        withRanked(rec("itk_00000003", IntakeStatus::Proposed), "Test Collection A", {"Test Collection A"});
    IntakeRecord noProposal = rec("itk_0000000b", IntakeStatus::Resolved);
    CHECK(findEntry(buildActionTable({&absent}, ctx()), IntakeAction::AssignTo) == nullptr, "ranked absent: none");
    CHECK(findEntry(buildActionTable({&empty}, ctx()), IntakeAction::AssignTo) == nullptr, "ranked []: none");
    CHECK(findEntry(buildActionTable({&onlyTarget}, ctx()), IntakeAction::AssignTo) == nullptr,
          "ranked = [target]: none");
    CHECK(titles(buildActionTable({&noProposal}, ctx())) ==
              v({"Propose", kOther, "Approve", kReject, kExecute, "Resume placement", kSwap, kDelete, "Refresh intake status"}),
          "no proposal (itk_0000000b): the picker only");
    CHECK(titles(buildActionTable({&empty}, ctx())) ==
              v({"Propose", kOther, "Approve", kReject, kExecute, "Resume placement", kSwap, kDelete, "Refresh intake status"}),
          "user-only proposal (itk_00000018): the picker only");

    // Status gating, one root with alternates.
    const IntakeStatus statuses[] = {IntakeStatus::New,    IntakeStatus::Resolved, IntakeStatus::Proposed,
                                     IntakeStatus::Approved, IntakeStatus::Placing,  IntakeStatus::Placed,
                                     IntakeStatus::GcDone, IntakeStatus::Rejected, IntakeStatus::Unknown};
    const bool listed[] = {true, true, true, true, false, false, false, false, false};
    const char *statusNames[] = {"new", "resolved", "proposed", "approved", "placing",
                                 "placed", "gc_done", "rejected", "unknown"};
    for (size_t i = 0; i < 9; i++) {
        IntakeRecord r = withRanked(rec("itk_00000004", statuses[i]), "Test Collection A",
                                    {"Test Collection A", "Test Collection B"});
        ActionTable st = buildActionTable({&r}, ctx());
        const ActionEntry *qa = findEntry(st, IntakeAction::AssignTo);
        const ActionEntry *other = findEntry(st, IntakeAction::AssignOther);
        const std::string what = std::string("status ") + statusNames[i];
        CHECK((qa != nullptr) == listed[i], (what + ": quick assign listed").c_str());
        CHECK(other != nullptr && other->enabled == listed[i], (what + ": picker listed, enabled when legal").c_str());
    }

    // Exactly one selected root.
    IntakeRecord d2 = withRanked(rec("itk_00000010", IntakeStatus::Approved), "Test Collection A",
                                 {"Test Collection A", "Test Collection C"});
    ActionTable two = buildActionTable({&d, &d2}, ctx());
    CHECK(findEntry(two, IntakeAction::AssignTo) == nullptr, "two roots: no quick assign");
    IntakeRecord placed = rec("itk_00000012", IntakeStatus::Placed);
    CHECK(findEntry(buildActionTable({&d, &placed}, ctx()), IntakeAction::AssignTo) == nullptr,
          "two roots, one qualifying: still no quick assign (m = 2)");

    // Rows left out by the menu's path budget may be other roots: one
    // mapped root is not a one-root selection.
    ActionContext incomplete = ctx();
    incomplete.selectionIncomplete = true;
    ActionTable partial = buildActionTable({&d}, incomplete);
    CHECK(findEntry(partial, IntakeAction::AssignTo) == nullptr, "incomplete selection: no quick assign");
    CHECK(titles(partial) == v({"Propose", kOther, "Approve", kReject, kExecute, "Resume placement", kSwap, kDelete, "Refresh intake status"}),
          "incomplete selection: the picker and the rest stay");
    CHECK(findEntry(partial, IntakeAction::AssignOther)->enabled, "incomplete selection: the picker is enabled");
}

static void testAssignOtherOrder() {
    g_context = "assign-other-order";
    // itk_0000000e: proposed, needs_review, target B, ranked [B, A, T&A].
    IntakeRecord e = withRanked(rec("itk_0000000e", IntakeStatus::Proposed), "Test Collection B",
                                {"Test Collection B", "Test Collection A", "Test & Ambient"});
    e.needsReview = true;
    ActionTable t = buildActionTable({&e}, ctx());
    CHECK(titles(t) == v({kOther, "Propose", "Assign to Test Collection A", "Assign to Test & Ambient", "Approve",
                          kReject, kExecute, "Resume placement", kSwap, kDelete, "Refresh intake status"}),
          "amber: the picker first, the rest in kOrder");
    CHECK(t.entries[0].action == IntakeAction::AssignOther && t.entries[0].enabled, "first entry is the picker");
    CHECK(t.entries.back().action == IntakeAction::Refresh, "Refresh stays last");

    // itk_0000000c: resolved, needs_review, no proposal.
    IntakeRecord c = rec("itk_0000000c", IntakeStatus::Resolved);
    c.needsReview = true;
    CHECK(titles(buildActionTable({&c}, ctx())) == v({kOther, "Propose", "Approve", kReject, kExecute, "Resume placement", kSwap, kDelete, "Refresh intake status"}),
          "amber resolved root: the picker first");

    // needs_review on new (CR-004.8) or a stray one on approved: not amber.
    IntakeRecord n = rec("itk_00000016", IntakeStatus::New);
    n.needsReview = true;
    CHECK(buildActionTable({&n}, ctx()).entries[0].action == IntakeAction::Propose, "new + needs_review: kOrder");
    IntakeRecord a = withRanked(rec("itk_00000010", IntakeStatus::Approved), "Test Collection A",
                                {"Test Collection A", "Test Collection C"});
    a.needsReview = true;
    CHECK(buildActionTable({&a}, ctx()).entries[0].action == IntakeAction::Propose, "approved + stray flag: kOrder");

    IntakeRecord d = withRanked(rec("itk_0000000d", IntakeStatus::Proposed), "Test Collection A",
                                {"Test Collection A", "Test Collection B"});
    CHECK(!assignOtherFirst({&d}, ctx()) && assignOtherFirst({&d, &e}, ctx()), "any amber qualifying root counts");
    CHECK(titles(buildActionTable({&d, &e}, ctx())) ==
              v({kOther, "Propose", "Approve", kReject, kExecute, "Resume placement", kSwap, kDelete, "Refresh intake status"}),
          "mixed d + e: picker first, no quick assign, no (n of m) when both qualify");
    IntakeRecord placedFlag = rec("itk_00000012", IntakeStatus::Placed);
    placedFlag.needsReview = true;
    CHECK(!assignOtherFirst({&d, &placedFlag}, ctx()), "a flag on a root the picker cannot run on does not count");

    // Busy lane: order kept, everything mutating disabled.
    ActionContext busy = ctx();
    busy.laneBusy = true;
    ActionTable b = buildActionTable({&e}, busy);
    CHECK(b.entries[0].action == IntakeAction::AssignOther && !b.entries[0].enabled, "busy: still first, disabled");
    CHECK(!b.entries[2].enabled && !b.entries[3].enabled, "busy: quick entries disabled");
    busy.executeRunning = true;
    ActionTable x = buildActionTable({&e}, busy);
    CHECK(x.entries[0].title == "Assign to other collection (execute running)" + kEllipsis,
          "execute running: said so, the ellipsis last");
    CHECK(x.entries[2].title == "Assign to Test Collection A (execute running)", "quick entry: said so, no ellipsis");
}

static void testAssignOtherMixed() {
    g_context = "assign-other-mixed";
    IntakeRecord d = withRanked(rec("itk_0000000d", IntakeStatus::Proposed), "Test Collection A",
                                {"Test Collection A", "Test Collection B"});
    IntakeRecord placed = rec("itk_00000012", IntakeStatus::Placed);
    placed.hasPlaced = placed.placedVerified = true;
    IntakeRecord rejected = rec("itk_00000014", IntakeStatus::Rejected);
    IntakeRecord n = rec("itk_0000000a", IntakeStatus::New);
    ActionTable t = buildActionTable({&d, &placed, &rejected, &n}, ctx());
    const ActionEntry *other = findEntry(t, IntakeAction::AssignOther);
    CHECK(other != nullptr && other->title == "Assign to other collection (2 of 4)" + kEllipsis,
          "(n of m) before the ellipsis");
    CHECK(other->enabled && ids(*other) == v({"itk_0000000d", "itk_0000000a"}), "runs on the qualifying roots only");
    CHECK(t.selectedRoots == 4, "m = 4");
    ActionTable none = buildActionTable({&placed, &rejected}, ctx());
    const ActionEntry *off = findEntry(none, IntakeAction::AssignOther);
    CHECK(off != nullptr && !off->enabled && off->roots.empty() && off->title == kOther,
          "no qualifying root: disabled, no (0 of m)");
    ActionContext busy = ctx();
    busy.laneBusy = true;
    busy.executeRunning = true;
    CHECK(findEntry(buildActionTable({&d, &placed}, busy), IntakeAction::AssignOther)->title ==
              "Assign to other collection (1 of 2) (execute running)" + kEllipsis,
          "title order: base, (n of m), (execute running), ellipsis");
    CHECK(actionRootFor(d).targetCollection == "Test Collection A" && actionRootFor(n).targetCollection.empty(),
          "the captured root carries its current target");
    IntakeRecord withPath = withProposal(rec("itk_00000010", IntakeStatus::Approved));
    IntakeRecord pending = withProposal(rec("itk_00000011", IntakeStatus::Approved), TargetPathState::Null);
    IntakeRecord older = withProposal(rec("itk_00000012", IntakeStatus::Approved), TargetPathState::Unknown);
    older.proposal.targetPath = "/ignored";
    CHECK(actionRootFor(withPath).targetPath == "/library/Test Collection A/x" &&
              actionRootFor(pending).targetPath.empty() && actionRootFor(older).targetPath.empty() &&
              actionRootFor(n).targetPath.empty(),
          "and its target_path only when set (errors naming the target go to it)");
}

static void testAssignArgv() {
    g_context = "assign-argv";
    IntakeRecord d = withRanked(rec("itk_0000000d", IntakeStatus::Proposed), "Test Collection A",
                                {"Test Collection A", "Test & Ambient"});
    IntakeRecord e = withRanked(rec("itk_0000000e", IntakeStatus::Proposed), "Test Collection B",
                                {"Test Collection B"});
    ActionTable one = buildActionTable({&d}, ctx());
    const ActionEntry *quick = findEntry(one, IntakeAction::AssignTo);
    CHECK(quick != nullptr &&
              argvFor(*quick) == v({kCli, "assign", "itk_0000000d", "--collection", "Test & Ambient", "--by", "user",
                                    "--json"}),
          "quick assign: assign <id> --collection X --by user --json, X literal");

    ActionTable two = buildActionTable({&d, &e}, ctx());
    ActionEntry picked = *findEntry(two, IntakeAction::AssignOther);
    CliRequest req;
    std::string why;
    CHECK(!requestForEntry(picked, "", req, &why) && why == "no collection",
          "the picker entry runs nothing until a collection is chosen");
    picked.collection = "Test Collection C";
    CHECK(argvFor(picked) == v({kCli, "assign", "itk_0000000d", "itk_0000000e", "--collection", "Test Collection C",
                                "--by", "user", "--json"}),
          "picked: assign <ids> --collection <name> --by user --json");
    CHECK(requestForEntry(picked, "ignored", req) && req.reason.empty() && req.command == CliCommand::Assign,
          "assign takes no reason");
    ActionEntry noRoots = picked;
    noRoots.roots.clear();
    CHECK(!requestForEntry(noRoots, "", req, &why) && why == "no qualifying root", "never with zero ids");
}

static void testLabels() {
    g_context = "labels";
    ActionRoot full;
    full.id = "itk_0000000b";
    full.albumartist = "Fixture Artist";
    full.album = "Resolved Album";
    full.rootPath = "/income/dump/Fixture Artist - Resolved Album";
    CHECK(albumLabel(full) == "Fixture Artist \xE2\x80\x93 Resolved Album", "artist – album");
    ActionRoot noAlbum = full;
    noAlbum.album.clear();
    CHECK(albumLabel(noAlbum) == "Fixture Artist", "only the artist");
    ActionRoot onlyAlbum = full;
    onlyAlbum.albumartist.clear();
    CHECK(albumLabel(onlyAlbum) == "Resolved Album", "only the album");
    ActionRoot folder = full;
    folder.albumartist.clear();
    folder.album.clear();
    folder.rootPath = "/income/shop/Loose Tracks/";
    CHECK(albumLabel(folder) == "Loose Tracks", "neither: the folder name");

    std::vector<ActionRoot> twelve;
    for (int i = 0; i < 12; i++) {
        ActionRoot r = full;
        r.album = "Album " + std::to_string(i);
        twelve.push_back(r);
    }
    const std::string text = affectedAlbumsText(twelve);
    size_t lines = 1;
    for (char c : text) lines += c == '\n';
    CHECK(lines == 11, "10 albums, then one more line");
    CHECK(text.substr(text.rfind('\n') + 1) == "and 2 more", "and N more");
    std::vector<ActionRoot> three(twelve.begin(), twelve.begin() + 3);
    CHECK(affectedAlbumsText(three).find("more") == std::string::npos, "three albums: all listed");
}

static void testActionIds() {
    g_context = "action-ids";
    uint32_t serial = 0;
    size_t index = 0;
    const uint32_t id = encodeActionId(0x123456, 7);
    CHECK(decodeActionId(id, serial, index) && serial == 0x123456 && index == 7, "round trip");
    CHECK(!decodeActionId(encodeActionId(0, 3), serial, index), "serial 0 is never valid");
    CHECK(nextMenuSerial(0) == 1 && nextMenuSerial(5) == 6, "serials count up");
    CHECK(nextMenuSerial(0xFFFFFF) == 1, "the serial wraps past 0");
    CHECK(decodeActionId(encodeActionId(nextMenuSerial(0xFFFFFF), 254), serial, index) && index == 254,
          "the last index fits");
}

// --- B9: Swap to library paths and Delete local copy… ---

static IntakeRecord placedRec(const char *id, bool verified = true) {
    IntakeRecord r = rec(id, IntakeStatus::Placed);
    r.hasPlaced = true;
    r.placedVerified = verified;
    r.placedTargetPath = std::string("/library/Test Collection A/") + id;
    return r;
}

static void testSwapDelete() {
    g_context = "swap-delete";
    IntakeRecord placed = placedRec("itk_00000012");
    IntakeRecord unverified = placedRec("itk_00000020", false);
    IntakeRecord gcDone = rec("itk_00000013", IntakeStatus::GcDone);
    gcDone.hasPlaced = gcDone.placedVerified = true;
    IntakeRecord rejected = rec("itk_00000014", IntakeStatus::Rejected);
    IntakeRecord approved = withProposal(rec("itk_00000010", IntakeStatus::Approved));

    ActionTable one = buildActionTable({&placed}, ctx());
    const ActionEntry *swap = findEntry(one, IntakeAction::Swap);
    const ActionEntry *del = findEntry(one, IntakeAction::DeleteLocal);
    CHECK(swap && swap->enabled && swap->title == kSwap && ids(*swap) == v({"itk_00000012"}),
          "Swap on a placed, verified root: enabled, no ellipsis (no dialog)");
    CHECK(del && del->enabled && del->title == kDelete && ids(*del) == v({"itk_00000012"}),
          "Delete local copy… on it: enabled, the ellipsis (confirm_gc on)");
    CHECK(del->roots[0].placedVerified && del->roots[0].placedTargetPath == "/library/Test Collection A/itk_00000012" &&
              del->roots[0].status == IntakeStatus::Placed,
          "the captured root carries status, placed.verified and the placed target");
    CHECK(one.entries[one.entries.size() - 3].action == IntakeAction::Swap &&
              one.entries[one.entries.size() - 2].action == IntakeAction::DeleteLocal,
          "doc 04 order: Swap, Delete, then Refresh last");

    for (const IntakeRecord *r : {&unverified, &gcDone, &rejected, &approved}) {
        ActionTable t = buildActionTable({r}, ctx());
        const ActionEntry *s = findEntry(t, IntakeAction::Swap);
        const ActionEntry *d = findEntry(t, IntakeAction::DeleteLocal);
        const std::string what = r->id;
        CHECK(s && !s->enabled && s->roots.empty(), (what + ": Swap listed, disabled").c_str());
        CHECK(d && !d->enabled && d->roots.empty(), (what + ": Delete listed, disabled").c_str());
    }

    ActionTable mixed = buildActionTable({&placed, &rejected, &approved}, ctx());
    CHECK(findEntry(mixed, IntakeAction::Swap)->title == "Swap to library paths (1 of 3)", "Swap: (n of m)");
    CHECK(findEntry(mixed, IntakeAction::DeleteLocal)->title == "Delete local copy (1 of 3)" + kEllipsis &&
              ids(*findEntry(mixed, IntakeAction::DeleteLocal)) == v({"itk_00000012"}),
          "Delete: (n of m) before the ellipsis, the placed root only (never the rejected one)");

    // An execute holds the lane: Delete disabled and labelled, Swap not.
    ActionContext running = ctx();
    running.laneBusy = true;
    running.executeRunning = true;
    ActionTable busy = buildActionTable({&placed}, running);
    const ActionEntry *busyDelete = findEntry(busy, IntakeAction::DeleteLocal);
    const ActionEntry *busySwap = findEntry(busy, IntakeAction::Swap);
    CHECK(!busyDelete->enabled && busyDelete->title == "Delete local copy (execute running)" + kEllipsis,
          "Delete disabled \"(execute running)\" during a run");
    CHECK(busySwap->enabled && busySwap->title == kSwap && ids(*busySwap) == v({"itk_00000012"}),
          "Swap stays enabled and unlabelled: it runs no CLI command");
    ActionContext dry = ctx();
    dry.laneBusy = true;
    ActionTable dryBusy = buildActionTable({&placed}, dry);
    CHECK(!findEntry(dryBusy, IntakeAction::DeleteLocal)->enabled &&
              findEntry(dryBusy, IntakeAction::DeleteLocal)->title == kDelete && findEntry(dryBusy, IntakeAction::Swap)->enabled,
          "another lane holder: Delete disabled without the label, Swap enabled");

    // confirm_gc off: no ellipsis.
    ActionContext noConfirm = ctx();
    noConfirm.confirmGc = false;
    CHECK(findEntry(buildActionTable({&placed}, noConfirm), IntakeAction::DeleteLocal)->title == "Delete local copy",
          "confirm_gc off: Delete runs at once, no ellipsis");
    CHECK(actionAsksFirst(IntakeAction::DeleteLocal, ctx()) && !actionAsksFirst(IntakeAction::DeleteLocal, noConfirm) &&
              !actionAsksFirst(IntakeAction::Swap, ctx()),
          "actionAsksFirst follows confirm_gc; Swap never asks");
    CHECK(findEntry(buildActionTable({&placed, &approved}, noConfirm), IntakeAction::DeleteLocal)->title ==
              "Delete local copy (1 of 2)",
          "confirm_gc off, mixed: no ellipsis either");

    // Rows already swapped (the library index): library roots count toward
    // m and qualify for Delete only.
    CHECK(libraryOnlyRoots({&approved}, {&placed, nullptr, &placed}) == std::vector<const IntakeRecord *>({&placed}),
          "library roots: deduplicated, unmapped rows skipped");
    CHECK(libraryOnlyRoots({&placed}, {&placed}).empty(), "a root also selected by an income row is an income root");
    ActionTable lib = buildActionTable({&approved}, ctx(), menuActions(), {&placed});
    CHECK(lib.selectedRoots == 2, "m counts income and library roots");
    const ActionEntry *libDelete = findEntry(lib, IntakeAction::DeleteLocal);
    CHECK(libDelete->enabled && libDelete->title == "Delete local copy (1 of 2)" + kEllipsis &&
              ids(*libDelete) == v({"itk_00000012"}),
          "Delete through the library index");
    const ActionEntry *libSwap = findEntry(lib, IntakeAction::Swap);
    CHECK(!libSwap->enabled && libSwap->roots.empty() && libSwap->title == kSwap,
          "Swap never runs on library rows (already swapped)");
    CHECK(findEntry(lib, IntakeAction::Execute)->title == kExecute.substr(0, kExecute.size() - kEllipsis.size()) +
                                                              " (1 of 2)" + kEllipsis,
          "the income root's actions count the library root in m");
    ActionTable libOnly = buildActionTable({}, ctx(), menuActions(), {&placed});
    CHECK(libOnly.selectedRoots == 1 && findEntry(libOnly, IntakeAction::DeleteLocal)->enabled &&
              findEntry(libOnly, IntakeAction::DeleteLocal)->title == kDelete &&
              !findEntry(libOnly, IntakeAction::Swap)->enabled && !findEntry(libOnly, IntakeAction::Propose)->enabled,
          "only swapped rows: Delete enabled (no n of m), everything else disabled");
    CHECK(!findEntry(buildActionTable({}, ctx(), menuActions(), {&unverified}), IntakeAction::DeleteLocal)->enabled,
          "a library root without placed.verified does not qualify");
    ActionContext inert = ctx();
    inert.inert = true;
    CHECK(titles(buildActionTable({}, inert, menuActions(), {&placed})) == v({"Refresh intake status"}),
          "inert: Refresh only, library roots too");
}

static void testGcGuard() {
    g_context = "gc-guard";
    ActionEntry e;
    e.action = IntakeAction::DeleteLocal;
    e.enabled = true;
    // A hand-made entry, bypassing the table: whatever the caller holds,
    // only roots captured as placed reach gc.
    IntakeRecord placed = placedRec("itk_00000012");
    IntakeRecord second = placedRec("itk_00000016");
    IntakeRecord rejected = rec("itk_00000014", IntakeStatus::Rejected);
    IntakeRecord gcDone = rec("itk_00000013", IntakeStatus::GcDone);
    IntakeRecord approved = withProposal(rec("itk_00000010", IntakeStatus::Approved));
    e.roots = {actionRootFor(placed), actionRootFor(rejected), actionRootFor(gcDone), actionRootFor(placed),
               actionRootFor(approved), actionRootFor(second)};
    std::vector<std::string> eligible;
    for (const ActionRoot &r : gcEligibleRoots(e.roots)) eligible.push_back(r.id);
    CHECK(eligible == v({"itk_00000012", "itk_00000016"}), "gcEligibleRoots: placed only, each once, in order");
    CHECK(argvFor(e) == v({kCli, "gc", "itk_00000012", "itk_00000016", "--json"}),
          "gc <placed ids> --json: rejected, gc_done and approved roots never passed");

    ActionEntry none = e;
    none.roots = {actionRootFor(rejected), actionRootFor(gcDone), actionRootFor(approved)};
    CliRequest request;
    std::string why;
    CHECK(!requestForEntry(none, std::string(), request, &why) && why.find("no placed root") != std::string::npos,
          "no placed root left: nothing runs");
    ActionEntry empty = e;
    empty.roots.clear();
    CHECK(!requestForEntry(empty, std::string(), request, &why) && why == "no qualifying root", "zero ids: never run");
    ActionEntry off = e;
    off.enabled = false;
    CHECK(!requestForEntry(off, std::string(), request, &why) && why == "disabled", "a disabled entry runs nothing");

    CliRequest bare;
    bare.command = CliCommand::Gc;
    CHECK(buildInvocation(cliConfig(), bare).status == BuildStatus::Refused, "IntakeCommandArgs refuses gc with no ids");
    bare.dryRun = true;
    CHECK(buildInvocation(cliConfig(), bare).status == BuildStatus::Refused, "and gc --dry-run with no ids");
    bool anyAll = false;
    for (const std::string &arg : argvFor(e)) anyAll = anyAll || arg == "--all" || arg.rfind("--all", 0) == 0;
    CHECK(!anyAll, "never --all");

    CHECK(actionIsMutating(IntakeAction::DeleteLocal) && !actionIsMutating(IntakeAction::Swap),
          "Delete is a mutating call, Swap is not");
    CliCommand command = CliCommand::Version;
    CHECK(actionCommand(IntakeAction::DeleteLocal, command) && command == CliCommand::Gc &&
              !actionCommand(IntakeAction::Swap, command),
          "Delete runs gc; Swap no CLI command");
    CliRequest gcRequest;
    gcRequest.command = CliCommand::Gc;
    gcRequest.ids = {"itk_00000012"};
    CHECK(commandClass(gcRequest) == CommandClass::Mutating,
          "gc is class Mutating (reported at 10 s, not killed before 15 min)");
    ActionEntry swapEntry;
    swapEntry.action = IntakeAction::Swap;
    swapEntry.enabled = true;
    swapEntry.roots = {actionRootFor(placed)};
    CHECK(!requestForEntry(swapEntry, std::string(), request, &why) && why == "not a CLI command",
          "Swap never becomes a CLI request");
}

int main() {
    @autoreleasepool {
        // An empty folder as the only bun search directory: no bun found.
        std::string base = NSTemporaryDirectory().UTF8String;
        if (base.empty() || base.back() != '/') base += '/';
        std::vector<char> dirTemplate;
        for (char ch : base + "intake-actiontable-XXXXXX") dirTemplate.push_back(ch);
        dirTemplate.push_back('\0');
        const char *dir = mkdtemp(dirTemplate.data());
        g_emptyDir = dir ? dir : "/nonexistent-intake-test-dir";
        testEnableMatrix();
        testEnableConditions();
        testAlternates();
        testTableRules();
        testMixed();
        testLane();
        testAllActionsExposed();
        testArgv();
        testMenuActions();
        testExecuteResume();
        testQuickAssign();
        testAssignOtherOrder();
        testAssignOtherMixed();
        testAssignArgv();
        testLabels();
        testActionIds();
        testSwapDelete();
        testGcGuard();
        if (dir) rmdir(dir);
    }
    TEST_MAIN_END();
}
