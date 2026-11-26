//
//  IntakeMutationResultTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeMutationResult (which root an error belongs to,
//  path-less errors that name an id included, the tooltip text, the console
//  line) and IntakeRootErrors (the lastError lifecycle: shown until the
//  root's status changes from the one the menu showed; timeout errors, which
//  Refresh also clears: clearTimeouts, ordinary and timeout errors replacing
//  each other, a hard-cap kill's errors as Integration stores them).
//  Synthetic envelopes,
//  plus real replies of Tests/mock-cli/intake-mock (a fresh state directory
//  under the test's temp root): a partial approve with E_BAD_STATUS, and a
//  propose on two virtual roots sharing one folder. B9: gc results (done,
//  E_VERIFY naming placed.target_path, E_NO_JOURNAL naming the root folder,
//  a partial with E_BAD_STATUS), synthetic and from the mock's gc states
//  (placed-gc_done, gc-e_verify, gc-e_no_journal).
//
// TEST_DEPS: src/Core/IntakeEnvelope.mm src/Core/IntakeErrorMap.mm src/Core/IntakePath.mm
// TEST_DEPS: src/Core/IntakeLog.mm src/Core/IntakeCommandArgs.mm src/Core/IntakeSemver.mm
// TEST_DEPS: src/Core/IntakeSettingsParse.mm src/Core/IntakeRootErrors.mm src/Core/IntakeStatusModel.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeCommandArgs.h"
#include "../src/Core/IntakeMutationResult.h"
#include "../src/Core/IntakeRootErrors.h"
#include "../src/Core/IntakeStatusModel.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <cstdlib>
#include <string>
#include <vector>

using namespace intake;

namespace {

const std::string kDump = "/income/dump/";
const std::string kLoose = "/income/shop/Loose Tracks";

MutationRoot root(const char *id, const std::string &path, IntakeStatus status = IntakeStatus::Unknown) {
    return MutationRoot{id, path, status};
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

std::string errorFor(const MutationOutcome &o, const std::string &id) {
    for (const auto &e : o.rootErrors) {
        if (e.first == id) return e.second;
    }
    return "<none>";
}

bool contains(const std::string &haystack, const std::string &needle) {
    return haystack.find(needle) != std::string::npos;
}

IntakeRecord record(const char *id, IntakeStatus status) {
    IntakeRecord r;
    r.id = id;
    r.rootPath = r.rootKey = kDump + id;
    r.status = status;
    return r;
}

} // namespace

static void testOk() {
    g_context = "ok";
    const std::vector<MutationRoot> roots = {root("itk_0000000b", kDump + "B"), root("itk_0000000c", kDump + "C")};
    MutationOutcome o = summarizeMutation(CliCommand::Propose, roots, env(CliOutcome::Ok, rows({"itk_0000000b", "itk_0000000c"})));
    CHECK(o.succeeded == std::vector<std::string>({"itk_0000000b", "itk_0000000c"}), "both succeeded");
    CHECK(o.rootErrors.empty() && o.failedWithoutError.empty() && !o.isError, "no errors");
    CHECK(o.consoleLine == "propose: done for 2 roots", "console line");
    MutationOutcome one = summarizeMutation(CliCommand::Reject, {roots[0]}, env(CliOutcome::Ok, rows({"itk_0000000b"})));
    CHECK(one.consoleLine == "reject: done for 1 root", "singular");
}

static void testPartial() {
    g_context = "partial";
    const std::vector<MutationRoot> roots = {root("itk_0000000d", kDump + "Proposed"),
                                             root("itk_0000000b", kDump + "Resolved"),
                                             root("itk_00000010", kDump + "Approved")};
    MutationOutcome o = summarizeMutation(
        CliCommand::Approve, roots,
        env(CliOutcome::Partial, rows({"itk_0000000d", "itk_00000010"}),
            {err("E_BAD_STATUS", "cannot approve from status resolved", kDump + "Resolved")}));
    CHECK(o.succeeded == std::vector<std::string>({"itk_0000000d", "itk_00000010"}), "exit 1 applies the subset");
    CHECK(o.rootErrors.size() == 1, "one root failed");
    CHECK(errorFor(o, "itk_0000000b") == "approve: Not allowed in the current state: cannot approve from status resolved",
          "E_BAD_STATUS goes to its root, without repeating the root's folder");
    CHECK(o.isError && contains(o.consoleLine, "approve: done for 2 of 3 roots"), "console: n of m");
    CHECK(contains(o.consoleLine, "(" + kDump + "Resolved)"), "console: the path is kept there");
}

static void testFailedGeneral() {
    g_context = "failed";
    const std::vector<MutationRoot> roots = {root("itk_0000000b", kDump + "B"), root("itk_0000000c", kDump + "C")};
    MutationOutcome o =
        summarizeMutation(CliCommand::Propose, roots, env(CliOutcome::Failed, nil, {err("E_NO_RULES", "no rules dir")}));
    CHECK(o.succeeded.empty() && o.rootErrors.size() == 2, "exit 2: every root failed");
    CHECK(errorFor(o, "itk_0000000c") == "propose: Intake rules not configured: no rules dir",
          "a command-level error goes to every root");
    CHECK(o.isError && contains(o.consoleLine, "propose failed for 2 roots: Intake rules not configured"),
          "console: failed");

    MutationOutcome unknown = summarizeMutation(
        CliCommand::Reject, {roots[0]}, env(CliOutcome::Failed, nil, {err("E_MOCK_UNKNOWN_CODE", "something new")}));
    CHECK(errorFor(unknown, "itk_0000000b") == "reject: something new", "unknown code: rendered from msg");
    MutationOutcome bare =
        summarizeMutation(CliCommand::Reject, {roots[0]}, env(CliOutcome::Failed, nil, {err("E_MOCK_BARE", "")}));
    CHECK(errorFor(bare, "itk_0000000b") == "reject: E_MOCK_BARE", "unknown code without msg: the code");
    MutationOutcome elsewhere = summarizeMutation(
        CliCommand::Reject, {roots[0]}, env(CliOutcome::Failed, nil, {err("E_MOCK_PATH", "", "/elsewhere/x")}));
    CHECK(errorFor(elsewhere, "itk_0000000b") == "reject: E_MOCK_PATH (/elsewhere/x)", "a foreign path is kept");
    MutationOutcome internal = summarizeMutation(
        CliCommand::Approve, {roots[0]}, env(CliOutcome::Failed, nil, {err("E_INTERNAL", "boom")}));
    CHECK(errorFor(internal, "itk_0000000b") == "approve: Intake CLI internal error: boom", "E_INTERNAL is per command");
}

static void testSharedFolder() {
    g_context = "shared-folder";
    // Virtual roots and the single share one folder (mock default scenario).
    const std::vector<MutationRoot> two = {root("itk_00000017", kLoose), root("itk_00000019", kLoose)};
    MutationOutcome o = summarizeMutation(
        CliCommand::Propose, two,
        env(CliOutcome::Partial, rows({"itk_00000017"}),
            {err("E_NO_TARGET", "cannot propose: singles slot pending", kLoose)}));
    CHECK(o.succeeded == std::vector<std::string>({"itk_00000017"}), "the album succeeded");
    CHECK(errorFor(o, "itk_00000019") == "propose: No target collection: cannot propose: singles slot pending",
          "the folder's error goes to the root that failed");
    CHECK(errorFor(o, "itk_00000017") == "<none>", "not to the one that succeeded");

    const std::vector<MutationRoot> both = {root("itk_00000016", kLoose), root("itk_00000017", kLoose)};
    MutationOutcome ordered = summarizeMutation(
        CliCommand::Approve, both,
        env(CliOutcome::Failed, nil,
            {err("E_BAD_STATUS", "cannot approve from status new", kLoose),
             err("E_BAD_STATUS", "cannot approve from status resolved", kLoose)}));
    CHECK(contains(errorFor(ordered, "itk_00000016"), "from status new") &&
              !contains(errorFor(ordered, "itk_00000016"), "resolved"),
          "k-th error of a folder to the k-th failed root there (first)");
    CHECK(contains(errorFor(ordered, "itk_00000017"), "from status resolved"), "(second)");

    MutationOutcome surplus = summarizeMutation(
        CliCommand::Approve, {root("itk_00000016", kLoose)},
        env(CliOutcome::Failed, nil, {err("E_A", "first", kLoose), err("E_B", "second", kLoose)}));
    CHECK(errorFor(surplus, "itk_00000016") == "approve: first \xC2\xB7 second", "surplus errors join the last root");

    MutationOutcome byId = summarizeMutation(
        CliCommand::Approve, both, env(CliOutcome::Partial, rows({"itk_00000016"}),
                                       {err("E_NOT_FOUND", "no sidecar with that id", "itk_00000017")}));
    CHECK(errorFor(byId, "itk_00000017") == "approve: Release not found: no sidecar with that id",
          "a path that is an id names that root");
}

static void testHostAndNfd() {
    g_context = "host";
    const std::vector<MutationRoot> roots = {root("itk_0000000b", kDump + "B"), root("itk_0000000c", kDump + "C")};
    MutationOutcome noCli = summarizeMutation(CliCommand::Reject, roots, hostNoCli("spawn failed (errno 2)"));
    CHECK(noCli.rootErrors.size() == 2, "E_NO_CLI fails every root");
    CHECK(errorFor(noCli, "itk_0000000b") == "reject: Intake CLI not available: spawn failed (errno 2)", "its text");
    CHECK(noCli.isError && contains(noCli.consoleLine, "reject failed for 2 roots"), "console");
    MutationOutcome timeout = summarizeMutation(CliCommand::Approve, roots, hostTimeout("killed at the 15-minute cap"));
    CHECK(contains(errorFor(timeout, "itk_0000000c"), "Intake CLI timed out"), "timeout at the cap");
    EnvelopeResult cancelled;
    cancelled.outcome = CliOutcome::Cancelled;
    MutationOutcome c = summarizeMutation(CliCommand::Approve, roots, cancelled);
    CHECK(c.rootErrors.empty() && c.failedWithoutError.size() == 2 && !c.isError, "cancelled: no tooltip");

    // NFD in the error path, NFC in the status root_path.
    const std::string nfc = kDump + "Caf\xC3\xA9";
    const std::string nfd = kDump + "Cafe\xCC\x81";
    MutationOutcome n = summarizeMutation(CliCommand::Approve, {root("itk_0000000b", nfc)},
                                          env(CliOutcome::Failed, nil, {err("E_BAD_STATUS", "cannot approve", nfd)}));
    CHECK(errorFor(n, "itk_0000000b") == "approve: Not allowed in the current state: cannot approve",
          "folders compare as normalized keys");

    MutationOutcome quiet = summarizeMutation(CliCommand::Approve, roots,
                                              env(CliOutcome::Partial, rows({"itk_0000000b"}), {}));
    CHECK(quiet.failedWithoutError == std::vector<std::string>({"itk_0000000c"}), "failed without an error is noted");
}

static void testErrorStore() {
    g_context = "error-store";
    RootErrorStore store;
    store.set("itk_0000000b", "propose: No target collection");
    CHECK(store.size() == 1 && store.errorFor("itk_0000000b") == "propose: No target collection", "set");

    std::vector<IntakeRecord> load = {record("itk_0000000b", IntakeStatus::Resolved),
                                      record("itk_0000000c", IntakeStatus::Resolved)};
    load[1].lastError = "stale text carried over";
    store.apply(load);
    CHECK(load[0].lastError == "propose: No target collection", "the first load shows it");
    CHECK(load[1].lastError.empty(), "a root without an error gets none (carried text cleared)");

    std::vector<IntakeRecord> same = {record("itk_0000000b", IntakeStatus::Resolved)};
    store.apply(same);
    CHECK(same[0].lastError == "propose: No target collection", "same status: still shown");

    std::vector<IntakeRecord> moved = {record("itk_0000000b", IntakeStatus::Proposed)};
    store.apply(moved);
    CHECK(moved[0].lastError.empty() && store.size() == 0, "status changed: dropped");
    std::vector<IntakeRecord> back = {record("itk_0000000b", IntakeStatus::Resolved)};
    store.apply(back);
    CHECK(back[0].lastError.empty(), "and it does not come back");

    // Without a baseline (Unknown) the first load's status is taken.
    store.set("itk_0000000d", "approve: Not allowed in the current state: cannot approve from status approved");
    std::vector<IntakeRecord> stale = {record("itk_0000000d", IntakeStatus::Approved)};
    store.apply(stale);
    CHECK(!stale[0].lastError.empty(), "the baseline is the first load's status");

    store.set("itk_0000000d", "approve: newer");
    std::vector<IntakeRecord> again = {record("itk_0000000d", IntakeStatus::Approved)};
    store.apply(again);
    CHECK(again[0].lastError == "approve: newer", "a newer error replaces the old one");

    store.clear("itk_0000000d");
    std::vector<IntakeRecord> cleared = {record("itk_0000000d", IntakeStatus::Approved)};
    store.apply(cleared);
    CHECK(cleared[0].lastError.empty() && store.size() == 0, "success clears it");

    store.set("itk_0000000e", "reject: x");
    std::vector<IntakeRecord> absent = {record("itk_0000000b", IntakeStatus::Resolved)};
    store.apply(absent);
    CHECK(store.size() == 0, "a root missing from a load is dropped");

    store.set("itk_0000000e", "reject: x");
    store.set("itk_0000000e", "");
    CHECK(store.size() == 0, "an empty text clears");
    store.set("itk_0000000e", "a");
    store.set("itk_0000000f", "b");
    store.clearAll();
    CHECK(store.size() == 0, "clearAll");
}

// A load whose `status` call started before the error was set may have
// read an older status: it shows the error but decides nothing about it
// (finding: a run ending while an FSEvents reload was in flight).
static void testErrorStoreInFlight() {
    g_context = "error-store-in-flight";
    using Clock = RootErrorStore::Clock;
    const Clock::time_point t0 = Clock::now();
    const Clock::time_point t1 = t0 + std::chrono::milliseconds(10);
    const Clock::time_point t2 = t0 + std::chrono::milliseconds(20);

    // Execute failed (no baseline): the in-flight load read placing, the
    // CLI then wrote approved. The next load shows approved.
    RootErrorStore store;
    store.set("itk_00000010", "execute: Verification failed: verify failed: hash", IntakeStatus::Unknown, t1);
    std::vector<IntakeRecord> inFlight = {record("itk_00000010", IntakeStatus::Placing)};
    store.apply(inFlight, t0);
    CHECK(inFlight[0].lastError == "execute: Verification failed: verify failed: hash",
          "a load started before the error shows it");
    std::vector<IntakeRecord> next = {record("itk_00000010", IntakeStatus::Approved)};
    store.apply(next, t2);
    CHECK(!next[0].lastError.empty() && store.size() == 1,
          "it did not take the stale status as the baseline: the next load keeps it");
    std::vector<IntakeRecord> later = {record("itk_00000010", IntakeStatus::Approved)};
    store.apply(later, t2 + std::chrono::milliseconds(10));
    CHECK(!later[0].lastError.empty(), "and it stays while the root stays approved");
    std::vector<IntakeRecord> moved = {record("itk_00000010", IntakeStatus::Placing)};
    store.apply(moved, t2 + std::chrono::milliseconds(20));
    CHECK(moved[0].lastError.empty() && store.size() == 0, "until the status changes");

    // A reverted resume (baseline approved): the in-flight load still saw
    // placing and must not drop it.
    RootErrorStore reverted;
    reverted.set("itk_00000011", "resume: reverted to approved", IntakeStatus::Approved, t1);
    std::vector<IntakeRecord> stale = {record("itk_00000011", IntakeStatus::Placing)};
    reverted.apply(stale, t0);
    CHECK(!stale[0].lastError.empty() && reverted.size() == 1, "an older read never drops a newer error");
    std::vector<IntakeRecord> fresh = {record("itk_00000011", IntakeStatus::Approved)};
    reverted.apply(fresh, t2);
    CHECK(!fresh[0].lastError.empty(), "the next load (approved) keeps it");

    // Missing from an in-flight load: kept too.
    RootErrorStore missing;
    missing.set("itk_00000012", "execute: x", IntakeStatus::Unknown, t1);
    std::vector<IntakeRecord> none = {record("itk_0000000b", IntakeStatus::Resolved)};
    missing.apply(none, t0);
    CHECK(missing.size() == 1, "a root missing from an older read is not dropped");
    missing.apply(none, t2);
    CHECK(missing.size() == 0, "a newer read drops it");

    // The same instant counts as possibly older.
    RootErrorStore same;
    same.set("itk_00000013", "execute: y", IntakeStatus::Approved, t1);
    std::vector<IntakeRecord> other = {record("itk_00000013", IntakeStatus::Placing)};
    same.apply(other, t1);
    CHECK(same.size() == 1, "an error set at the call's start is not judged by it");
}

// Timeout errors (E_CLI_TIMEOUT: a 10 s report, a hard-cap kill): the same
// lifecycle, and Refresh drops them (clearTimeouts) while real per-root
// errors stay.
static void testErrorStoreTimeouts() {
    g_context = "error-store-timeouts";
    // onBudget's text: the command's name first, never the code.
    const std::string tenSeconds = "propose: Intake CLI timed out: still running after 10 s; it is not stopped, "
                                   "and intake refreshes when it exits";
    RootErrorStore store;
    store.set("itk_00000020", "propose: No target collection", IntakeStatus::Resolved);
    store.setTimeout("itk_00000021", tenSeconds, IntakeStatus::Resolved);
    store.setTimeout("itk_00000022", tenSeconds, IntakeStatus::Resolved);
    CHECK(store.size() == 3 && store.errorFor("itk_00000021") == tenSeconds, "a timeout error is set like any");
    CHECK(!store.isTimeout("itk_00000020") && store.isTimeout("itk_00000021"), "only setTimeout marks it");
    std::vector<IntakeRecord> load = {record("itk_00000020", IntakeStatus::Resolved),
                                      record("itk_00000021", IntakeStatus::Resolved),
                                      record("itk_00000022", IntakeStatus::Resolved)};
    store.apply(load);
    CHECK(load[1].lastError == tenSeconds && load[2].lastError == tenSeconds, "shown in the rows like any error");

    CHECK_EQ(store.clearTimeouts(), 2, "clearTimeouts drops the timeout errors and counts them");
    CHECK(store.size() == 1 && store.errorFor("itk_00000020") == "propose: No target collection",
          "a real per-root error stays");
    std::vector<IntakeRecord> after = {record("itk_00000020", IntakeStatus::Resolved),
                                       record("itk_00000021", IntakeStatus::Resolved),
                                       record("itk_00000022", IntakeStatus::Resolved)};
    store.apply(after);
    CHECK(!after[0].lastError.empty() && after[1].lastError.empty() && after[2].lastError.empty(),
          "the reload after it shows only the real error");
    CHECK_EQ(store.clearTimeouts(), 0, "nothing left to clear");

    g_context = "error-store-timeouts/replace";
    // An ordinary error replaces a timeout one, mark included...
    RootErrorStore replace;
    replace.setTimeout("itk_00000023", tenSeconds, IntakeStatus::Resolved);
    replace.set("itk_00000023", "propose: No target collection", IntakeStatus::Resolved);
    CHECK(!replace.isTimeout("itk_00000023") && replace.errorFor("itk_00000023") == "propose: No target collection",
          "ordinary replaces timeout");
    CHECK(replace.clearTimeouts() == 0 && replace.size() == 1, "and Refresh keeps it");
    // ...and a timeout error replaces an ordinary one (the newer wins).
    replace.setTimeout("itk_00000023", tenSeconds, IntakeStatus::Resolved);
    CHECK(replace.isTimeout("itk_00000023") && replace.errorFor("itk_00000023") == tenSeconds,
          "timeout replaces ordinary");
    CHECK(replace.clearTimeouts() == 1 && replace.size() == 0, "and Refresh drops it");
    // The call ends after its 10 s report (onFinished): its roots' errors
    // are cleared, then its result sets ordinary ones.
    replace.setTimeout("itk_00000024", tenSeconds, IntakeStatus::Resolved);
    replace.clear("itk_00000024");
    replace.set("itk_00000024", "propose: No target collection", IntakeStatus::Resolved);
    CHECK(!replace.isTimeout("itk_00000024") && replace.clearTimeouts() == 0, "the result's error is no timeout");
    replace.setTimeout("itk_00000025", "", IntakeStatus::Resolved);
    CHECK(replace.size() == 1 && replace.errorFor("itk_00000025").empty(), "an empty timeout text clears too");
    replace.setTimeout("itk_00000026", tenSeconds);
    replace.clearAll();
    CHECK(replace.size() == 0 && replace.clearTimeouts() == 0, "clearAll drops timeout errors too");

    g_context = "error-store-timeouts/apply";
    // apply() keeps its rules for a timeout error: dropped when the status
    // changes from the baseline, kept while it stays.
    RootErrorStore lifecycle;
    lifecycle.setTimeout("itk_00000027", tenSeconds, IntakeStatus::Resolved);
    lifecycle.setTimeout("itk_00000028", tenSeconds);  // no baseline: the first load's
    std::vector<IntakeRecord> same = {record("itk_00000027", IntakeStatus::Resolved),
                                      record("itk_00000028", IntakeStatus::Proposed)};
    lifecycle.apply(same);
    lifecycle.apply(same);
    CHECK(same[0].lastError == tenSeconds && same[1].lastError == tenSeconds && lifecycle.size() == 2,
          "kept while the status stays");
    std::vector<IntakeRecord> moved = {record("itk_00000027", IntakeStatus::Proposed),
                                       record("itk_00000028", IntakeStatus::Proposed)};
    lifecycle.apply(moved);
    CHECK(moved[0].lastError.empty() && !moved[1].lastError.empty() && lifecycle.size() == 1,
          "dropped when the status changes");
    CHECK(lifecycle.isTimeout("itk_00000028"), "a baseline taken from a load keeps the mark");
    std::vector<IntakeRecord> gone = {record("itk_0000000b", IntakeStatus::Resolved)};
    lifecycle.apply(gone);
    CHECK(lifecycle.size() == 0, "a root missing from a load is dropped");
    using Clock = RootErrorStore::Clock;
    const Clock::time_point t0 = Clock::now();
    lifecycle.setTimeout("itk_00000029", tenSeconds, IntakeStatus::Resolved, t0 + std::chrono::milliseconds(10));
    std::vector<IntakeRecord> older = {record("itk_00000029", IntakeStatus::Proposed)};
    lifecycle.apply(older, t0);
    CHECK(older[0].lastError == tenSeconds && lifecycle.size() == 1, "an older read decides nothing about it");

    g_context = "error-store-timeouts/hard-cap";
    // A propose killed at the hard cap, as Integration stores it: outcome
    // Timeout gives every root the host's E_CLI_TIMEOUT, stored with
    // setTimeout; E_NO_CLI stays an ordinary error.
    const std::vector<MutationRoot> two = {root("itk_0000002a", kDump + "A", IntakeStatus::Resolved),
                                           root("itk_0000002b", kDump + "B", IntakeStatus::Resolved)};
    const EnvelopeResult capped = hostTimeout("still running at the hard cap; terminated");
    const MutationOutcome o = summarizeMutation(CliCommand::Propose, two, capped);
    CHECK(capped.outcome == CliOutcome::Timeout && o.rootErrors.size() == 2 && o.succeeded.empty(),
          "a hard-cap kill names every root");
    bool allTimeout = true;
    for (const auto &e : o.rootErrors) allTimeout = allTimeout && contains(e.second, "timed out");
    CHECK(allTimeout, "each with the host's timeout error");
    RootErrorStore hardCap;
    for (const auto &e : o.rootErrors) {
        if (capped.outcome == CliOutcome::Timeout) {
            hardCap.setTimeout(e.first, e.second, IntakeStatus::Resolved);
        } else {
            hardCap.set(e.first, e.second, IntakeStatus::Resolved);
        }
    }
    hardCap.set("itk_0000002c", "propose: Intake CLI not available: exit code 127", IntakeStatus::Resolved);
    CHECK(hardCap.clearTimeouts() == 2 && hardCap.size() == 1 && !hardCap.errorFor("itk_0000002c").empty(),
          "Refresh clears the hard cap's tooltips, not E_NO_CLI's");
}

static void testPathlessIds() {
    g_context = "pathless-ids";
    const std::vector<MutationRoot> roots = {root("itk_0000000a", kDump + "A"), root("itk_0000000b", kDump + "B"),
                                             root("itk_0000000d", kDump + "D")};
    MutationOutcome o = summarizeMutation(
        CliCommand::Approve, roots,
        env(CliOutcome::Partial, rows({"itk_0000000b"}),
            {err("E_NOT_FOUND", "no sidecar with id itk_0000000a"), err("E_NOT_FOUND", "no sidecar with id itk_0000000d")}));
    CHECK(errorFor(o, "itk_0000000a") == "approve: Release not found: no sidecar with id itk_0000000a",
          "a path-less error naming an id goes to that root only");
    CHECK(errorFor(o, "itk_0000000d") == "approve: Release not found: no sidecar with id itk_0000000d",
          "and the other one to its own root");

    // Two virtual roots in one folder, named V2 then V1: V2's sidecar is
    // gone (E_NOT_FOUND, path null), V1 is refused by status (its folder).
    const std::vector<MutationRoot> virt = {root("itk_00000019", kLoose), root("itk_00000017", kLoose)};
    MutationOutcome v = summarizeMutation(
        CliCommand::Approve, virt,
        env(CliOutcome::Failed, nil,
            {err("E_NOT_FOUND", "no sidecar with id itk_00000019"),
             err("E_BAD_STATUS", "cannot approve from status resolved", kLoose)}));
    CHECK(errorFor(v, "itk_00000019") == "approve: Release not found: no sidecar with id itk_00000019",
          "the named root keeps its not-found error");
    CHECK(errorFor(v, "itk_00000017") == "approve: Not allowed in the current state: cannot approve from status resolved",
          "the folder's E_BAD_STATUS goes to the other root, not the named one");
    MutationOutcome reordered = summarizeMutation(
        CliCommand::Approve, virt,
        env(CliOutcome::Failed, nil,
            {err("E_BAD_STATUS", "cannot approve from status resolved", kLoose),
             err("E_NOT_FOUND", "no sidecar with id itk_00000019")}));
    CHECK(errorFor(reordered, "itk_00000017") == errorFor(v, "itk_00000017") &&
              errorFor(reordered, "itk_00000019") == errorFor(v, "itk_00000019"),
          "the same whatever the order of the errors");

    MutationOutcome word = summarizeMutation(CliCommand::Approve, {root("itk_0000000a", kDump + "A")},
                                             env(CliOutcome::Failed, nil, {err("E_MOCK_X", "about itk_0000000ab")}));
    CHECK(errorFor(word, "itk_0000000a") == "approve: about itk_0000000ab",
          "an id matches as a whole word only (this one names no root: the command's own)");
    MutationOutcome succeededNamed = summarizeMutation(
        CliCommand::Approve, {root("itk_0000000a", kDump + "A"), root("itk_0000000b", kDump + "B")},
        env(CliOutcome::Partial, rows({"itk_0000000a"}), {err("E_MOCK_WARN", "itk_0000000a was odd")}));
    CHECK(errorFor(succeededNamed, "itk_0000000b") == "<none>" &&
              succeededNamed.failedWithoutError == std::vector<std::string>({"itk_0000000b"}),
          "an error naming a root that succeeded is not broadcast to the others");
    MutationOutcome general = summarizeMutation(CliCommand::Approve, roots,
                                                env(CliOutcome::Failed, nil, {err("E_INTERNAL", "boom")}));
    CHECK(general.rootErrors.size() == 3, "an error naming no root still goes to every failed root");
}

// E_TARGET_EXISTS and the out-of-tier E_NO_TARGET name the target folder,
// not the root's (commands-p3.ts): each goes to the root with that target
// only, never to every root (rule 1c).
static void testTargetPaths() {
    g_context = "target-paths";
    std::vector<MutationRoot> roots = {root("itk_0000000a", kDump + "A"), root("itk_0000000b", kDump + "B"),
                                       root("itk_0000000c", kDump + "C")};
    roots[0].targetPath = "/lib/A";
    roots[1].targetPath = "/lib/B";
    roots[2].targetPath = "/lib/C";
    MutationOutcome o = summarizeMutation(
        CliCommand::Execute, roots,
        env(CliOutcome::Partial, rows({"itk_0000000c"}),
            {err("E_TARGET_EXISTS", "target path already exists", "/lib/A"),
             err("E_NO_TARGET", "target_path is outside all configured tier roots", "/lib/B")}),
        "execute dry run");
    CHECK(o.succeeded == std::vector<std::string>({"itk_0000000c"}) && o.rootErrors.size() == 2, "two refused roots");
    CHECK(errorFor(o, "itk_0000000a") == "execute dry run: Target folder already exists: target path already exists (/lib/A)",
          "A gets its own target's error only, with the path");
    CHECK(contains(errorFor(o, "itk_0000000b"), "outside all configured tier roots (/lib/B)") &&
              !contains(errorFor(o, "itk_0000000b"), "/lib/A"),
          "B gets its own target's error only");

    // A target error next to a folder error for another root in the same
    // folder (virtual roots): neither takes the other's slot.
    std::vector<MutationRoot> shared = {root("itk_00000017", kDump + "mixed"), root("itk_00000018", kDump + "mixed")};
    shared[0].targetPath = "/lib/17";
    shared[1].targetPath = "/lib/18";
    MutationOutcome s = summarizeMutation(
        CliCommand::Execute, shared,
        env(CliOutcome::Failed, nil,
            {err("E_BAD_STATUS", "cannot execute from status proposed", kDump + "mixed"),
             err("E_TARGET_EXISTS", "target path already exists", "/lib/17")}));
    CHECK(contains(errorFor(s, "itk_00000017"), "(/lib/17)") && !contains(errorFor(s, "itk_00000017"), "proposed"),
          "the target error goes to its root, though it came second");
    CHECK(contains(errorFor(s, "itk_00000018"), "cannot execute from status proposed") &&
              !contains(errorFor(s, "itk_00000018"), "/lib/17"),
          "the folder error goes to the other root in the folder");

    // Two roots with one target: the first failed root without an error.
    std::vector<MutationRoot> same = {root("itk_0000000a", kDump + "A"), root("itk_0000000b", kDump + "B")};
    same[0].targetPath = same[1].targetPath = "/lib/Same";
    MutationOutcome t = summarizeMutation(
        CliCommand::Execute, same,
        env(CliOutcome::Partial, rows({"itk_0000000a"}), {err("E_TARGET_EXISTS", "target path already exists", "/lib/Same")}));
    CHECK(t.rootErrors.size() == 1 && contains(errorFor(t, "itk_0000000b"), "(/lib/Same)"),
          "the root that failed gets it, the one placed there does not");

    // A target only a succeeded root has: placed nowhere, never broadcast.
    std::vector<MutationRoot> other = {root("itk_0000000a", kDump + "A"), root("itk_0000000b", kDump + "B")};
    other[0].targetPath = "/lib/A";
    MutationOutcome u = summarizeMutation(
        CliCommand::Execute, other,
        env(CliOutcome::Partial, rows({"itk_0000000a"}), {err("E_TARGET_EXISTS", "target path already exists", "/lib/A")}));
    CHECK(u.rootErrors.empty() && u.failedWithoutError == std::vector<std::string>({"itk_0000000b"}),
          "not copied to the other failed root");

    // Without target paths (CLI before 0.3.0) it stays the command's own.
    MutationOutcome old = summarizeMutation(
        CliCommand::Execute, {root("itk_0000000a", kDump + "A")},
        env(CliOutcome::Failed, nil, {err("E_TARGET_EXISTS", "target path already exists", "/lib/A")}));
    CHECK(contains(errorFor(old, "itk_0000000a"), "(/lib/A)"), "no target known: rule 3 as before");
}

static void testBaseline() {
    g_context = "baseline";
    // Propose on five resolved roots; the CLI threw after writing the first
    // two (exit 2, E_INTERNAL without a path): every root failed.
    std::vector<MutationRoot> five;
    for (const char *id : {"itk_0000000a", "itk_0000000b", "itk_0000000c", "itk_0000000d", "itk_0000000e"}) {
        five.push_back(root(id, kDump + id, IntakeStatus::Resolved));
    }
    MutationOutcome o =
        summarizeMutation(CliCommand::Propose, five, env(CliOutcome::Failed, nil, {err("E_INTERNAL", "boom")}));
    CHECK(o.rootErrors.size() == 5, "a whole-call failure names every root");
    RootErrorStore store;
    for (const auto &e : o.rootErrors) store.set(e.first, e.second, IntakeStatus::Resolved);
    std::vector<IntakeRecord> load = {
        record("itk_0000000a", IntakeStatus::Proposed), record("itk_0000000b", IntakeStatus::Proposed),
        record("itk_0000000c", IntakeStatus::Resolved), record("itk_0000000d", IntakeStatus::Resolved),
        record("itk_0000000e", IntakeStatus::Resolved)};
    store.apply(load);
    CHECK(load[0].lastError.empty() && load[1].lastError.empty(),
          "roots the CLI changed before failing show no tooltip at the first load");
    CHECK(load[2].lastError == "propose: Intake CLI internal error: boom" && !load[4].lastError.empty(),
          "roots still in the menu's status show it");
    CHECK(store.size() == 3, "the changed roots' errors are dropped");

    // A second click from a stale menu: X was resolved in the menu, the
    // first Propose had already made it proposed, the CLI said E_BAD_STATUS.
    RootErrorStore stale;
    stale.set("itk_0000000f", "propose: Not allowed in the current state: cannot propose from status proposed",
              IntakeStatus::Resolved);
    std::vector<IntakeRecord> after = {record("itk_0000000f", IntakeStatus::Proposed)};
    stale.apply(after);
    CHECK(after[0].lastError.empty() && stale.size() == 0,
          "a stale-menu error does not stay on the root's new status");

    RootErrorStore kept;
    kept.set("itk_0000000f", "approve: Not allowed in the current state: target unknown", IntakeStatus::Proposed);
    std::vector<IntakeRecord> same = {record("itk_0000000f", IntakeStatus::Proposed)};
    kept.apply(same);
    kept.apply(same);
    CHECK(!same[0].lastError.empty(), "a refusal on the status the menu showed stays while it lasts");
    std::vector<IntakeRecord> moved = {record("itk_0000000f", IntakeStatus::Approved)};
    kept.apply(moved);
    CHECK(moved[0].lastError.empty() && kept.size() == 0, "and goes when the status changes");
}

static std::string runMock(const std::string &state, CliRequest request, CliOutcome &outcome, EnvelopeResult &out) {
    CliConfig config;
    config.cliPath = mock::mockPath();
    config.bunSearchDirs = {mock::newDir("nobun")};
    config.baseEnvironment = mock::mockEnv(state);
    config.cliVersion = "0.3.0";
    config.cliListsCommands = true;
    CliInvocation inv = buildInvocation(config, request);
    if (inv.status != BuildStatus::Ok) return "build: " + inv.message;
    std::string stdoutText;
    const int code = mock::runCapture(inv.arguments, inv.environment, stdoutText);
    out = parseEnvelope(stdoutText, code);
    outcome = out.outcome;
    return std::string();
}

static void testAgainstMock() {
    g_context = "mock";
    const std::string state = mock::setupState("default");
    CHECK(!state.empty(), "mock state set up");
    if (state.empty()) return;

    CliRequest status;
    status.command = CliCommand::Status;
    CliOutcome outcome = CliOutcome::NoCli;
    EnvelopeResult statusEnv;
    CHECK(runMock(state, status, outcome, statusEnv).empty() && outcome == CliOutcome::Ok, "status ran");
    std::vector<IntakeRecord> records = parseStatusRows(statusEnv.data).records;
    auto rootOf = [&records](const char *id) {
        for (const IntakeRecord &r : records) {
            if (r.id == id) return MutationRoot{r.id, r.rootPath};
        }
        return MutationRoot{id, std::string()};
    };

    // approve d (proposed) and b (resolved): exit 1, E_BAD_STATUS on b.
    CliRequest approve;
    approve.command = CliCommand::Approve;
    approve.ids = {"itk_0000000d", "itk_0000000b"};
    EnvelopeResult approveEnv;
    CHECK(runMock(state, approve, outcome, approveEnv).empty() && outcome == CliOutcome::Partial, "approve: partial");
    CHECK(mock::lastLine(mock::callsLog(state)) == "approve\titk_0000000d\titk_0000000b\t--json",
          "calls.log has the argv the table built");
    MutationOutcome a = summarizeMutation(CliCommand::Approve, {rootOf("itk_0000000d"), rootOf("itk_0000000b")}, approveEnv);
    CHECK(a.succeeded == std::vector<std::string>({"itk_0000000d"}), "mock: d approved");
    CHECK(errorFor(a, "itk_0000000b") == "approve: Not allowed in the current state: cannot approve from status resolved",
          "mock: E_BAD_STATUS reaches b by its folder");

    // propose 17 and 19, two virtual roots in one folder: 19 is the single.
    CliRequest propose;
    propose.command = CliCommand::Propose;
    propose.ids = {"itk_00000017", "itk_00000019"};
    EnvelopeResult proposeEnv;
    CHECK(runMock(state, propose, outcome, proposeEnv).empty() && outcome == CliOutcome::Partial, "propose: partial");
    MutationOutcome p =
        summarizeMutation(CliCommand::Propose, {rootOf("itk_00000017"), rootOf("itk_00000019")}, proposeEnv);
    CHECK(p.succeeded == std::vector<std::string>({"itk_00000017"}), "mock: 17 proposed");
    CHECK(errorFor(p, "itk_00000019") == "propose: No target collection: cannot propose: singles slot pending",
          "mock: the folder's error goes to the single only");

    // reject with a reason: exit 0.
    CliRequest reject;
    reject.command = CliCommand::Reject;
    reject.ids = {"itk_0000000c"};
    reject.reason = "synthetic reason; with punctuation";
    EnvelopeResult rejectEnv;
    CHECK(runMock(state, reject, outcome, rejectEnv).empty() && outcome == CliOutcome::Ok, "reject: ok");
    CHECK(mock::lastLine(mock::callsLog(state)) ==
              "reject\titk_0000000c\t--reason\tsynthetic reason; with punctuation\t--json",
          "the reason arrives as one argument");
    MutationOutcome r = summarizeMutation(CliCommand::Reject, {rootOf("itk_0000000c")}, rejectEnv);
    CHECK(r.succeeded.size() == 1 && r.rootErrors.empty(), "mock: rejected");
}

// B9: `gc <ids> --json` results. Delete local copy… names each root with
// placed.target_path as its target (E_VERIFY names it, commands-p3.ts
// cmdGc) and its root folder (E_NO_JOURNAL, E_BAD_STATUS name that).
static void testGc() {
    g_context = "gc";
    const std::string placedDir = kDump + "Fixture Artist - Placed Album";
    const std::string target = "/library/music.hq/Test Collection A/Fixture Artist/Fixture Artist - 2026 - Placed Album";
    const std::string otherDir = kDump + "Fixture Artist - Other Placed";
    const std::string otherTarget = "/library/music.hq/Test Collection B/Other";
    const std::vector<MutationRoot> roots = {MutationRoot{"itk_00000012", placedDir, IntakeStatus::Placed, target},
                                             MutationRoot{"itk_00000020", otherDir, IntakeStatus::Placed, otherTarget}};
    MutationOutcome done = summarizeMutation(CliCommand::Gc, roots, env(CliOutcome::Ok, rows({"itk_00000012", "itk_00000020"})));
    CHECK(done.succeeded.size() == 2 && done.rootErrors.empty() && !done.isError && done.consoleLine == "gc: done for 2 roots",
          "done: the B6 console line");

    MutationOutcome verify = summarizeMutation(
        CliCommand::Gc, roots,
        env(CliOutcome::Partial, rows({"itk_00000020"}),
            {err("E_VERIFY", "target re-verification failed: missing: 01 - Test Track One.wav", target)}));
    CHECK(verify.succeeded == std::vector<std::string>({"itk_00000020"}), "partial: the other root was collected");
    CHECK(errorFor(verify, "itk_00000012") ==
              "gc: Verification failed: target re-verification failed: missing: 01 - Test Track One.wav (" + target + ")",
          "E_VERIFY names the placed target: it goes to that root, the path kept");
    CHECK(verify.isError && verify.consoleLine.rfind("gc: done for 1 of 2 roots; Verification failed", 0) == 0,
          "partial: Error line, n of m, the first error");

    MutationOutcome journal = summarizeMutation(
        CliCommand::Gc, roots,
        env(CliOutcome::Failed, nil, {err("E_NO_JOURNAL", "journal record missing or mismatched", otherDir)}));
    CHECK(errorFor(journal, "itk_00000020") == "gc: Intake journal unavailable: journal record missing or mismatched",
          "E_NO_JOURNAL names the root folder: that root, without repeating it");
    CHECK(errorFor(journal, "itk_00000012") == "<none>",
          "the other root has no error of its own (the call failed for it without one)");
    CHECK(journal.isError && journal.consoleLine ==
                                 "gc failed for 2 roots: Intake journal unavailable: journal record missing or mismatched (" +
                                     otherDir + ")",
          "exit 2: \"gc failed for N roots: ...\"");

    MutationOutcome mismatch = summarizeMutation(
        CliCommand::Gc, {MutationRoot{"itk_00000012", placedDir, IntakeStatus::Placed, std::string()}},
        env(CliOutcome::Failed, nil, {err("E_VERIFY", "placed target_path is outside all configured tier roots", "/elsewhere")}));
    CHECK(errorFor(mismatch, "itk_00000012") ==
              "gc: Verification failed: placed target_path is outside all configured tier roots (/elsewhere)",
          "an E_VERIFY path that is no known target: the command's own error, still on its root");
}

static void testGcAgainstMock() {
    g_context = "gc-mock";
    const std::string state = mock::setupState("default");
    CHECK(!state.empty(), "mock state set up");
    if (state.empty()) return;
    const std::string root = state + "/root";
    const std::string placedDir = root + "/income/dump/Fixture Artist - Placed Album";
    const std::string target = root + "/library/music.hq/Test Collection A/Fixture Artist/Fixture Artist - 2026 - Placed Album";
    const MutationRoot placed{"itk_00000012", placedDir, IntakeStatus::Placed, target};
    CliOutcome outcome = CliOutcome::NoCli;
    CliRequest gc;
    gc.command = CliCommand::Gc;
    gc.ids = {"itk_00000012"};

    // E_VERIFY through gc.start: the root stays placed, nothing deleted.
    CHECK(mock::writeFile(state + "/gc.start", "gc-e_verify\n"), "gc.start written");
    EnvelopeResult verifyEnv;
    CHECK(runMock(state, gc, outcome, verifyEnv).empty() && outcome == CliOutcome::Failed, "gc: exit 2 (E_VERIFY)");
    MutationOutcome verify = summarizeMutation(CliCommand::Gc, {placed}, verifyEnv);
    CHECK(errorFor(verify, "itk_00000012") ==
              "gc: Verification failed: target re-verification failed: missing: 01 - Test Track One.wav (" + target + ")",
          "mock: the E_VERIFY tooltip");
    CHECK(mock::fileExists(placedDir + "/01 - Test Track One.wav"), "mock: nothing deleted");

    const std::string state2 = mock::setupState("default");
    CHECK(mock::writeFile(state2 + "/gc.start", "gc-e_no_journal\n"), "gc.start written");
    EnvelopeResult journalEnv;
    CHECK(runMock(state2, gc, outcome, journalEnv).empty() && outcome == CliOutcome::Failed, "gc: exit 2 (E_NO_JOURNAL)");
    const MutationRoot placed2{"itk_00000012", state2 + "/root/income/dump/Fixture Artist - Placed Album",
                               IntakeStatus::Placed, state2 + "/root/library/x"};
    CHECK(errorFor(summarizeMutation(CliCommand::Gc, {placed2}, journalEnv), "itk_00000012") ==
              "gc: Intake journal unavailable: journal record missing or mismatched",
          "mock: the E_NO_JOURNAL tooltip");

    // Done, then placed-gc_done applied (gc.next): gc_done, local audio gone,
    // the library copy and the tombstone sidecar stay.
    const std::string state3 = mock::setupState("default");
    CHECK(mock::writeFile(state3 + "/gc.next", "placed-gc_done\n"), "gc.next written");
    EnvelopeResult doneEnv;
    CHECK(runMock(state3, gc, outcome, doneEnv).empty() && outcome == CliOutcome::Ok, "gc: exit 0");
    CHECK(mock::lastLine(mock::callsLog(state3)) == "gc\titk_00000012\t--json", "calls.log: gc <id> --json");
    const std::string dir3 = state3 + "/root/income/dump/Fixture Artist - Placed Album";
    MutationOutcome done = summarizeMutation(
        CliCommand::Gc, {MutationRoot{"itk_00000012", dir3, IntakeStatus::Placed, std::string()}}, doneEnv);
    CHECK(done.succeeded.size() == 1 && done.consoleLine == "gc: done for 1 root", "mock: gc: done for 1 root");
    CHECK(!mock::fileExists(dir3 + "/01 - Test Track One.wav") && !mock::fileExists(dir3 + "/02 - Test Track Two.wav") &&
              mock::fileExists(dir3 + "/.intake.json"),
          "mock: the local audio is gone, the sidecar stays");
    CHECK(mock::fileExists(state3 + "/root/library/music.hq/Test Collection A/Fixture Artist/Fixture Artist - 2026 - Placed "
                                    "Album/01 - Test Track One.wav"),
          "mock: the library copy stays");
    CliRequest status;
    status.command = CliCommand::Status;
    status.filters = {{"id", "itk_00000012"}};
    EnvelopeResult statusEnv;
    CHECK(runMock(state3, status, outcome, statusEnv).empty() && outcome == CliOutcome::Ok, "status ran");
    std::vector<IntakeRecord> records = parseStatusRows(statusEnv.data).records;
    CHECK(records.size() == 1 && records[0].status == IntakeStatus::GcDone, "mock: the root is gc_done now");
}

int main() {
    @autoreleasepool {
        // Construct the sweep's statics before registering it, so they are
        // destroyed after it runs at exit.
        mock::trackedMutex();
        mock::tracked();
        atexit([] { mock::killLeftovers(); });
        testOk();
        testPartial();
        testFailedGeneral();
        testSharedFolder();
        testHostAndNfd();
        testErrorStore();
        testErrorStoreInFlight();
        testErrorStoreTimeouts();
        testPathlessIds();
        testTargetPaths();
        testBaseline();
        testAgainstMock();
        testGc();
        testGcAgainstMock();
        mock::killLeftovers();
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
