//
//  IntakeMutationResultTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeMutationResult (which root an error belongs to, the
//  tooltip text, the console line) and IntakeRootErrors (the lastError
//  lifecycle: shown until the root's status changes). Synthetic envelopes,
//  plus real replies of Tests/mock-cli/intake-mock (a fresh state directory
//  under the test's temp root): a partial approve with E_BAD_STATUS, and a
//  propose on two virtual roots sharing one folder.
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

MutationRoot root(const char *id, const std::string &path) {
    return MutationRoot{id, path};
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

    // A stale menu: the error is shown on the status the CLI refused, once
    // it is first loaded.
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
        testAgainstMock();
        mock::killLeftovers();
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
