//
//  IntakeLoadPolicyTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeLoadPolicy (the inert-state decision of doc 03 v1.2,
//  the invalidation diff, alias application, status lines, the rules source
//  line) and IntakeDecorStats (the hidden decor_stats counters). Synthetic
//  records only.
//
// TEST_DEPS: src/Core/IntakeErrorMap.mm src/Core/IntakeEnvelope.mm src/Core/IntakePath.mm
// TEST_DEPS: src/Core/IntakeSnapshot.mm src/Core/IntakeLog.mm src/Core/IntakeDecorationMap.mm
// TEST_DEPS: src/Core/IntakeReviewRule.mm src/Core/IntakeMountAliases.mm src/Core/IntakeDecorStats.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeDecorStats.h"
#include "../src/Core/IntakeLoadPolicy.h"
#include "../src/Core/IntakePath.h"
#include "TestHarness.h"

#include <string>
#include <thread>
#include <vector>

using namespace intake;

static EnvelopeResult result(CliOutcome outcome, std::vector<std::string> codes = {}, std::string detail = {}) {
    EnvelopeResult r;
    r.outcome = outcome;
    for (const std::string &code : codes) {
        CliError e;
        e.code = code;
        e.msg = code == "E_NO_RULES" ? "no rules dir" : "";
        r.errors.push_back(e);
    }
    r.detail = std::move(detail);
    return r;
}

static void testFailureEffect() {
    g_context = "inert-rule";
    const EnvelopeResult noCli = hostNoCli("spawn failed");
    const EnvelopeResult timeout = hostTimeout("no exit within 10 s");
    const EnvelopeResult noRules = result(CliOutcome::Failed, {"E_NO_RULES"});
    const EnvelopeResult internal = result(CliOutcome::Failed, {"E_INTERNAL"});
    const EnvelopeResult badArgs = result(CliOutcome::Failed, {"E_BAD_ARGS"});
    const EnvelopeResult mixed = result(CliOutcome::Failed, {"E_PARSE", "E_NO_RULES"});
    const EnvelopeResult unknown = result(CliOutcome::Failed, {"E_SOMETHING_NEW"});

    // No status load has succeeded yet.
    CHECK(loadFailureEffect(LoadStep::Version, noCli, false) == LoadFailureEffect::Inert, "first version E_NO_CLI: inert");
    CHECK(loadFailureEffect(LoadStep::Version, timeout, false) == LoadFailureEffect::Inert,
          "first version E_CLI_TIMEOUT: inert");
    CHECK(loadFailureEffect(LoadStep::Version, noRules, false) == LoadFailureEffect::Inert,
          "first version E_NO_RULES: inert");
    CHECK(loadFailureEffect(LoadStep::Status, noCli, false) == LoadFailureEffect::Inert, "first status E_NO_CLI: inert");
    CHECK(loadFailureEffect(LoadStep::Status, timeout, false) == LoadFailureEffect::Inert,
          "first status E_CLI_TIMEOUT: inert");
    CHECK(loadFailureEffect(LoadStep::Status, noRules, false) == LoadFailureEffect::Inert,
          "first status E_NO_RULES: inert");
    CHECK(loadFailureEffect(LoadStep::Status, mixed, false) == LoadFailureEffect::Inert,
          "any provider-wide code among others: inert");
    CHECK(loadFailureEffect(LoadStep::Status, internal, false) == LoadFailureEffect::KeepLast,
          "first status E_INTERNAL: per command, not inert");
    CHECK(loadFailureEffect(LoadStep::Version, internal, false) == LoadFailureEffect::KeepLast,
          "first version E_INTERNAL: not inert");
    CHECK(loadFailureEffect(LoadStep::Status, badArgs, false) == LoadFailureEffect::KeepLast,
          "E_BAD_ARGS: not inert");
    CHECK(loadFailureEffect(LoadStep::Status, unknown, false) == LoadFailureEffect::KeepLast,
          "an unknown code: not inert");

    // After a successful load, a failed refresh keeps the last data.
    CHECK(loadFailureEffect(LoadStep::Status, noCli, true) == LoadFailureEffect::KeepLast,
          "refresh E_NO_CLI: keep the last data");
    CHECK(loadFailureEffect(LoadStep::Status, timeout, true) == LoadFailureEffect::KeepLast,
          "refresh E_CLI_TIMEOUT: keep");
    CHECK(loadFailureEffect(LoadStep::Status, noRules, true) == LoadFailureEffect::KeepLast,
          "refresh E_NO_RULES: keep");
    CHECK(loadFailureEffect(LoadStep::Version, noCli, true) == LoadFailureEffect::KeepLast,
          "version recheck E_NO_CLI: keep");
    CHECK(gateFailureEffect() == LoadFailureEffect::Inert, "a gate failure is always inert");

    g_context = "error-text";
    CHECK(loadErrorText(noRules) == "Intake rules not configured: no rules dir", "one error, rendered");
    CHECK(loadErrorText(mixed) == "Unreadable sidecar (+1 more)", "the first error and a count");
    CHECK(loadErrorText(noCli) == "Intake CLI not available: spawn failed", "a host-synthesized error");
    CHECK(loadErrorText(result(CliOutcome::Failed, {}, "odd")) == "odd", "no errors: the detail");
    CHECK(loadErrorText(result(CliOutcome::Failed)) == "unknown error (failed)", "nothing at all");
}

static IntakeRecord record(const std::string &id, const std::string &rootPath,
                           IntakeStatus status = IntakeStatus::Resolved) {
    IntakeRecord r;
    r.id = id;
    r.rootPath = rootPath;
    normalizePath(rootPath, r.rootKey);
    r.status = status;
    return r;
}

static RootMembers members(std::vector<std::string> paths, MemberSource source = MemberSource::Listed) {
    RootMembers m;
    m.kind = MemberKind::Members;
    m.source = source;
    m.relativePaths = std::move(paths);
    return m;
}

static void testRendersAlike() {
    g_context = "renders-alike";
    std::vector<IntakeRecord> base = {record("itk_00000001", "/income/a"),
                                      record("itk_00000002", "/income/singles", IntakeStatus::New),
                                      record("itk_00000003", "/income/singles", IntakeStatus::Proposed)};
    MemberTable table = {{"itk_00000002", members({"x.wav"})}, {"itk_00000003", members({"y.wav"})}};
    auto a = IntakeSnapshot::build(base, table);
    CHECK(rendersAlike(*a, *IntakeSnapshot::build(base, table)), "the same load renders alike");

    std::vector<IntakeRecord> reordered = {base[2], base[0], base[1]};
    CHECK(rendersAlike(*a, *IntakeSnapshot::build(reordered, table)), "row order does not matter");

    MemberTable otherSource = {{"itk_00000002", members({"x.wav"}, MemberSource::Previous)},
                               {"itk_00000003", members({"y.wav"}, MemberSource::Assumed)}};
    CHECK(rendersAlike(*a, *IntakeSnapshot::build(base, otherSource)), "where a member list came from does not matter");

    std::vector<IntakeRecord> status = base;
    status[0].status = IntakeStatus::Proposed;
    CHECK(!rendersAlike(*a, *IntakeSnapshot::build(status, table)), "a status change differs");

    std::vector<IntakeRecord> review = base;
    review[0].needsReview = true;
    CHECK(!rendersAlike(*a, *IntakeSnapshot::build(review, table)), "needs_review turning amber differs");

    std::vector<IntakeRecord> sameVisual = base;
    sameVisual[0].album = "Another Album";
    sameVisual[0].hasProposal = true;
    sameVisual[0].proposal.targetCollection = "Test Collection A";
    sameVisual[0].proposal.rankedState = RankedState::Present;
    CHECK(rendersAlike(*a, *IntakeSnapshot::build(sameVisual, table)), "fields that do not render do not count");

    std::vector<IntakeRecord> moved = base;
    moved[0].rootKey = "/income/b";
    CHECK(!rendersAlike(*a, *IntakeSnapshot::build(moved, table)), "a moved root differs");

    MemberTable grown = table;
    grown["itk_00000002"].relativePaths.push_back("z.wav");
    CHECK(!rendersAlike(*a, *IntakeSnapshot::build(base, grown)), "a changed member list differs");

    MemberTable kind = table;
    kind["itk_00000002"].kind = MemberKind::None;
    CHECK(!rendersAlike(*a, *IntakeSnapshot::build(base, kind)), "a changed member kind differs");

    MemberTable explicitWhole = table;
    explicitWhole["itk_00000001"] = RootMembers();  // WholeDirectory, Assumed
    CHECK(rendersAlike(*a, *IntakeSnapshot::build(base, explicitWhole)),
          "no member entry and an explicit whole-directory entry are the same");

    std::vector<IntakeRecord> fewer = {base[0], base[1]};
    CHECK(!rendersAlike(*a, *IntakeSnapshot::build(fewer, table)), "a removed root differs");
    std::vector<IntakeRecord> swapped = {base[0], base[1], record("itk_00000004", "/income/singles")};
    CHECK(!rendersAlike(*a, *IntakeSnapshot::build(swapped, table)), "same count, another id differs");

    IntakePalette palette;
    palette.tintNew = 0x11223344;
    CHECK(!rendersAlike(*a, *IntakeSnapshot::build(base, table, palette)), "a colour change differs");

    CHECK(rendersAlike(*IntakeSnapshot::empty(), *IntakeSnapshot::build({}, {})), "two empty snapshots");
    CHECK(!rendersAlike(*IntakeSnapshot::empty(), *a), "empty vs something");
}

static void testApplyAliases() {
    g_context = "apply-aliases";
    auto aliases = MountAliases::build({MountEntry{"/Volumes/share", "//user@host/share", "smbfs"}});
    std::vector<IntakeRecord> records = {record("itk_00000001", "/Volumes/share/income/a"),
                                         record("itk_00000002", "/Users/someone/income/b"),
                                         record("itk_00000003", "/Volumes/share/income/Mu\xCC\x81sica/")};
    records[1].rootKey = "stale";  // re-derived from rootPath
    applyMountAliases(records, *aliases);
    CHECK(records[0].rootKey == "/smbfs:share/income/a", "a root on the share gets the alias key");
    CHECK(records[1].rootKey == "/Users/someone/income/b", "a local root keeps its normalized path");
    CHECK(records[2].rootKey == "/smbfs:share/income/M\xC3\xBAsica", "NFD and a trailing slash normalized");
    CHECK(records[0].rootPath == "/Volumes/share/income/a", "rootPath stays as the CLI spelled it");
    applyMountAliases(records, *MountAliases::none());
    CHECK(records[0].rootKey == "/Volumes/share/income/a", "applying another table re-derives from rootPath");
    std::vector<IntakeRecord> bad = {record("itk_00000004", "relative/path")};
    applyMountAliases(bad, *aliases);
    CHECK(bad[0].rootKey.empty(), "an unusable rootPath gets an empty key");
}

static void testStatusLine() {
    g_context = "status-line";
    LoaderStatus s;
    s.state = LoaderState::NotConfigured;
    CHECK(statusLine(s) == "Not configured: no intake CLI path", "not configured");
    s.state = LoaderState::Loading;
    CHECK(statusLine(s) == "Loading\xE2\x80\xA6", "loading");
    s.state = LoaderState::Ready;
    s.cliVersion = "0.3.0";
    s.roots = 16;
    CHECK(statusLine(s) == "Ready \xC2\xB7 CLI 0.3.0 \xC2\xB7 16 roots", "ready");
    s.roots = 1;
    s.partialErrors = 1;
    s.error = "Unreadable sidecar";
    CHECK(statusLine(s) == "Ready \xC2\xB7 CLI 0.3.0 \xC2\xB7 1 root \xC2\xB7 1 error: Unreadable sidecar",
          "ready after a partial load");
    s.partialErrors = 0;
    s.state = LoaderState::Inert;
    s.error = "version: Intake CLI not available";
    CHECK(statusLine(s) == "Inactive: version: Intake CLI not available", "inert");
    s.state = LoaderState::Stale;
    s.roots = 16;
    s.error = "status: Intake CLI timed out";
    CHECK(statusLine(s) == "Refresh failed, showing the last data (CLI 0.3.0 \xC2\xB7 16 roots): status: Intake CLI "
                           "timed out",
          "stale");
    s.state = LoaderState::Failed;
    s.error = "status: Intake CLI internal error";
    CHECK(statusLine(s) == "Load failed: status: Intake CLI internal error", "failed");
    s.state = LoaderState::Stopped;
    CHECK(statusLine(s) == "Stopped", "stopped");
    CHECK(std::string(loaderStateName(LoaderState::Inert)) == "inactive", "state names");

    g_context = "rules-source";
    CliConfig config;
    CHECK(rulesSourceDescription(config) == "the CLI's own config.toml (no INTAKE_RULES_DIR)", "nothing set");
    config.baseEnvironment = std::vector<std::string>{"HOME=/Users/someone", "INTAKE_RULES_DIR=/tmp/rules-fixture"};
    CHECK(rulesSourceDescription(config) == "INTAKE_RULES_DIR inherited from the environment: /tmp/rules-fixture",
          "inherited");
    config.rulesDir = "/tmp/rules-pref";
    CHECK(rulesSourceDescription(config) == "rules folder from the rules_dir preference: /tmp/rules-pref",
          "the preference wins");
}

static void testDecorStats() {
    g_context = "decor-stats";
    DecorStats stats;
    DecorStatsFigures f = stats.figures();
    CHECK(f.loads == 0 && f.batches == 0 && f.items == 0, "starts at zero");
    stats.noteLoad();
    stats.noteBatch(64, 120);
    stats.noteBatch(32, 400);
    f = stats.figures();
    CHECK(f.loads == 1 && f.batches == 2 && f.items == 96 && f.itemsSinceInvalidation == 96, "counts batches and items");
    CHECK(f.batchMicrosTotal == 520 && f.batchMicrosMax == 400 && f.lastBatchItems == 32 && f.lastBatchMicros == 400,
          "times");
    stats.noteInvalidation();
    f = stats.figures();
    CHECK(f.invalidations == 1 && f.itemsSinceInvalidation == 0 && f.items == 96,
          "an invalidation restarts only the since-invalidation count");
    stats.noteBatch(10, 50);
    f = stats.figures();
    CHECK(f.itemsSinceInvalidation == 10 && f.batchMicrosMax == 400, "after the invalidation");
    const std::string line = DecorStats::formatLine(f);
    CHECK(line == "decor_stats: batch 10 items 50 us; since invalidation 10 items; totals 3 batches, 106 items, avg "
                  "190 us, max 400 us; loads 1, invalidations 1",
          "the log line");

    DecorStats concurrent;
    std::vector<std::thread> threads;
    for (int t = 0; t < 4; t++) {
        threads.emplace_back([&concurrent, t] {
            for (int i = 0; i < 1000; i++) concurrent.noteBatch(2, static_cast<uint64_t>(t * 1000 + i));
        });
    }
    for (std::thread &th : threads) th.join();
    f = concurrent.figures();
    CHECK(f.batches == 4000 && f.items == 8000 && f.batchMicrosMax == 3999, "batches from several queues at once");
}

int main(void) {
    @autoreleasepool {
        testFailureEffect();
        testRendersAlike();
        testApplyAliases();
        testStatusLine();
        testDecorStats();
    }
    TEST_MAIN_END();
}
