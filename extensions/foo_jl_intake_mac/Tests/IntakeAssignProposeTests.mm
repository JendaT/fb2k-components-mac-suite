//
//  IntakeAssignProposeTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeAssignPropose (B13-lite): which roots a successful
//  assign proposes next. Per status, per outcome (ok, partial, failed,
//  host errors, cancelled), errors naming a root, repeats and order. Also
//  through summarizeMutation on synthetic envelopes, as Integration calls
//  it. Synthetic ids and paths only.
//
// TEST_DEPS: src/Core/IntakeMutationResult.mm src/Core/IntakeEnvelope.mm src/Core/IntakeErrorMap.mm
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeLog.mm src/Core/IntakeCommandArgs.mm
// TEST_DEPS: src/Core/IntakeSemver.mm src/Core/IntakeSettingsParse.mm src/Core/IntakeStatusModel.mm
// TEST_DEPS: src/Core/IntakeRootErrors.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeAssignPropose.h"
#include "TestHarness.h"

#include <initializer_list>
#include <string>
#include <vector>

using namespace intake;

namespace {

MutationRoot root(const char *id, IntakeStatus status, const std::string &path = std::string()) {
    return MutationRoot{id, path.empty() ? std::string("/income/dump/") + id : path, status};
}

MutationOutcome succeeded(std::initializer_list<const char *> ids) {
    MutationOutcome o;
    for (const char *id : ids) o.succeeded.push_back(id);
    return o;
}

CliError err(const char *code, const char *msg, const std::string &path = std::string()) {
    CliError e;
    e.code = code;
    e.msg = msg;
    e.path = path;
    e.hasPath = !path.empty();
    return e;
}

EnvelopeResult env(CliOutcome outcome, NSArray *data, std::vector<CliError> errors = {}) {
    EnvelopeResult r;
    r.outcome = outcome;
    r.data = data;
    r.errors = std::move(errors);
    return r;
}

NSArray *rows(std::initializer_list<const char *> ids) {
    NSMutableArray *out = [NSMutableArray array];
    for (const char *id : ids) [out addObject:@{@"id" : @(id)}];
    return out;
}

bool idsAre(const std::vector<std::string> &got, std::initializer_list<const char *> want) {
    if (got.size() != want.size()) return false;
    size_t i = 0;
    for (const char *w : want) {
        if (got[i++] != w) return false;
    }
    return true;
}

} // anonymous namespace

static void testStatuses() {
    g_context = "statuses";
    const std::vector<MutationRoot> assigned = {
        root("itk_00000001", IntakeStatus::New),      root("itk_00000002", IntakeStatus::Resolved),
        root("itk_00000003", IntakeStatus::Proposed), root("itk_00000004", IntakeStatus::Approved),
        root("itk_00000005", IntakeStatus::Resolved),
    };
    const MutationOutcome all = succeeded({"itk_00000001", "itk_00000002", "itk_00000003", "itk_00000004",
                                           "itk_00000005"});
    const AssignFollowUp next = proposeAfterAssign(assigned, CliOutcome::Ok, all, {});
    CHECK(idsAre(next.propose, {"itk_00000002", "itk_00000005"}), "only the resolved roots, in naming order");
    CHECK(next.roots.size() == 2 && next.roots[0].id == "itk_00000002" && next.roots[1].id == "itk_00000005" &&
              next.roots[0].status == IntakeStatus::Resolved,
          "their roots as named, with the captured status");
    CHECK(idsAre(next.skipped, {"itk_00000001 (new)", "itk_00000003 (proposed)", "itk_00000004 (approved)"}),
          "new, proposed and approved are skipped");
    CHECK(next.skippedLine == "assign: no propose for 3 roots not resolved before the assign: itk_00000001 (new), "
                              "itk_00000003 (proposed), itk_00000004 (approved)",
          "one Debug line for the skipped");

    const AssignFollowUp one =
        proposeAfterAssign({root("itk_00000001", IntakeStatus::New)}, CliOutcome::Ok, succeeded({"itk_00000001"}), {});
    CHECK(one.propose.empty() && one.skippedLine == "assign: no propose for 1 root not resolved before the assign: "
                                                    "itk_00000001 (new)",
          "a single skipped root: singular");

    const AssignFollowUp resolvedOnly = proposeAfterAssign({root("itk_00000002", IntakeStatus::Resolved)},
                                                           CliOutcome::Ok, succeeded({"itk_00000002"}), {});
    CHECK(idsAre(resolvedOnly.propose, {"itk_00000002"}) && resolvedOnly.skipped.empty() &&
              resolvedOnly.skippedLine.empty(),
          "nothing skipped: no line");

    const AssignFollowUp others =
        proposeAfterAssign({root("itk_00000006", IntakeStatus::Placed), root("itk_00000007", IntakeStatus::Unknown)},
                           CliOutcome::Ok, succeeded({"itk_00000006", "itk_00000007"}), {});
    CHECK(others.propose.empty() && others.skipped.size() == 2, "any other status is skipped too");
}

static void testOutcomes() {
    g_context = "outcomes";
    const std::vector<MutationRoot> assigned = {root("itk_00000002", IntakeStatus::Resolved),
                                                root("itk_00000005", IntakeStatus::Resolved)};
    const MutationOutcome both = succeeded({"itk_00000002", "itk_00000005"});
    CHECK(proposeAfterAssign(assigned, CliOutcome::Ok, both, {}).propose.size() == 2, "ok: both");
    MutationOutcome partial = succeeded({"itk_00000005"});
    partial.rootErrors.push_back({"itk_00000002", "assign: Not allowed in the current state"});
    const AssignFollowUp p = proposeAfterAssign(assigned, CliOutcome::Partial, partial, {});
    CHECK(idsAre(p.propose, {"itk_00000005"}) && p.skipped.empty(), "partial: only the root that succeeded");

    const CliOutcome nothing[] = {CliOutcome::Failed, CliOutcome::NoCli, CliOutcome::Timeout, CliOutcome::Cancelled};
    int none = 0;
    for (CliOutcome o : nothing) {
        // Even with ids in `succeeded` (it cannot happen, but the outcome
        // decides first).
        const AssignFollowUp next = proposeAfterAssign(assigned, o, both, {});
        if (next.propose.empty() && next.skipped.empty() && next.skippedLine.empty()) none++;
    }
    CHECK_EQ(none, 4, "exit 2, E_NO_CLI, E_CLI_TIMEOUT and cancelled propose nothing");
}

static void testErrors() {
    g_context = "errors";
    const std::vector<MutationRoot> assigned = {root("itk_00000002", IntakeStatus::Resolved),
                                                root("itk_00000005", IntakeStatus::Resolved)};
    const MutationOutcome both = succeeded({"itk_00000002", "itk_00000005"});
    MutationOutcome flagged = both;
    flagged.rootErrors.push_back({"itk_00000005", "assign: something"});
    CHECK(idsAre(proposeAfterAssign(assigned, CliOutcome::Partial, flagged, {}).propose, {"itk_00000002"}),
          "a root with an error is not proposed, even when it is in data");
    CHECK(idsAre(proposeAfterAssign(assigned, CliOutcome::Partial, both,
                                    {err("E_INTERNAL", "boom", "itk_00000002")})
                     .propose,
                 {"itk_00000005"}),
          "an error whose path is the id rules it out");
    CHECK(proposeAfterAssign(assigned, CliOutcome::Partial, both,
                             {err("E_INTERNAL", "boom", "/income/dump/elsewhere")})
                  .propose.size() == 2,
          "an error about another folder does not");
    MutationOutcome failedOnly;
    failedOnly.failedWithoutError = {"itk_00000002", "itk_00000005"};
    CHECK(proposeAfterAssign(assigned, CliOutcome::Partial, failedOnly, {}).propose.empty(),
          "roots missing from data are not proposed");
    MutationOutcome mixed = succeeded({"itk_00000003"});
    mixed.rootErrors.push_back({"itk_00000004", "assign: Not allowed in the current state"});
    const AssignFollowUp m = proposeAfterAssign(
        {root("itk_00000003", IntakeStatus::Proposed), root("itk_00000004", IntakeStatus::New)}, CliOutcome::Partial,
        mixed, {});
    CHECK(idsAre(m.skipped, {"itk_00000003 (proposed)"}), "a failed root is not listed as skipped: its error shows");
}

static void testOrderAndRepeats() {
    g_context = "order";
    const std::vector<MutationRoot> assigned = {root("itk_00000009", IntakeStatus::Resolved),
                                                root("itk_00000002", IntakeStatus::Resolved),
                                                root("itk_00000009", IntakeStatus::Resolved)};
    const AssignFollowUp next =
        proposeAfterAssign(assigned, CliOutcome::Ok, succeeded({"itk_00000002", "itk_00000009"}), {});
    CHECK(idsAre(next.propose, {"itk_00000009", "itk_00000002"}) && next.roots.size() == 2,
          "the assign's naming order, a repeat counted once");
    CHECK(proposeAfterAssign({}, CliOutcome::Ok, MutationOutcome(), {}).propose.empty(), "no roots: nothing");
}

// As Integration calls it: summarizeMutation on the assign's envelope first.
static void testThroughSummary() {
    g_context = "summary";
    const std::vector<MutationRoot> assigned = {root("itk_00000001", IntakeStatus::New),
                                                root("itk_00000002", IntakeStatus::Resolved),
                                                root("itk_00000005", IntakeStatus::Resolved)};
    const EnvelopeResult ok = env(CliOutcome::Ok, rows({"itk_00000001", "itk_00000002", "itk_00000005"}));
    const AssignFollowUp a =
        proposeAfterAssign(assigned, ok.outcome, summarizeMutation(CliCommand::Assign, assigned, ok), ok.errors);
    CHECK(idsAre(a.propose, {"itk_00000002", "itk_00000005"}) && idsAre(a.skipped, {"itk_00000001 (new)"}),
          "exit 0: the resolved roots, the new one skipped");

    const EnvelopeResult partial =
        env(CliOutcome::Partial, rows({"itk_00000001", "itk_00000005"}),
            {err("E_BAD_STATUS", "cannot assign from status placing", "/income/dump/itk_00000002")});
    const AssignFollowUp b = proposeAfterAssign(assigned, partial.outcome,
                                                summarizeMutation(CliCommand::Assign, assigned, partial),
                                                partial.errors);
    CHECK(idsAre(b.propose, {"itk_00000005"}), "exit 1: the root whose folder the error names is left out");

    const EnvelopeResult failed = env(CliOutcome::Failed, nil, {err("E_NO_RULES", "rules folder missing")});
    const AssignFollowUp c =
        proposeAfterAssign(assigned, failed.outcome, summarizeMutation(CliCommand::Assign, assigned, failed),
                           failed.errors);
    CHECK(c.propose.empty() && c.skipped.empty(), "exit 2: nothing");
}

int main(void) {
    @autoreleasepool {
        testStatuses();
        testOutcomes();
        testErrors();
        testOrderAndRepeats();
        testThroughSummary();
    }
    TEST_MAIN_END();
}
