//
//  IntakeLoadPolicyTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeLoadPolicy (the inert-state decision of doc 03 v1.2,
//  the invalidation diffs of a load and of a remount, alias application,
//  keeping the last record of a root whose sidecar a partial `status` could
//  not read, status lines, the rules source line) and IntakeDecorStats (the
//  hidden decor_stats counters). Synthetic records only.
//
// TEST_DEPS: src/Core/IntakeErrorMap.mm src/Core/IntakeEnvelope.mm src/Core/IntakePath.mm
// TEST_DEPS: src/Core/IntakeSnapshot.mm src/Core/IntakeLog.mm src/Core/IntakeDecorationMap.mm
// TEST_DEPS: src/Core/IntakeReviewRule.mm src/Core/IntakeMountAliases.mm src/Core/IntakeDecorStats.mm
// TEST_DEPS: src/Core/IntakeWatchFilter.mm
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

static CliError parseError(const std::string &path, const std::string &code = "E_PARSE") {
    CliError e;
    e.code = code;
    e.msg = "unreadable sidecar";
    e.path = path;
    e.hasPath = true;
    return e;
}

static bool hasId(const std::vector<IntakeRecord> &records, const std::string &id) {
    for (const IntakeRecord &r : records) {
        if (r.id == id) return true;
    }
    return false;
}

static void testCarryOverUnreadable() {
    g_context = "carry-over";
    const std::vector<IntakeRecord> previous = {
        record("itk_00000001", "/income/dump/Album One"),
        record("itk_00000002", "/income/dump/Album Two", IntakeStatus::Proposed),
        record("itk_00000016", "/income/shop/Loose Tracks"),
        record("itk_00000017", "/income/shop/Loose Tracks"),
        record("itk_00000020", "/income/dump/Mu\xCC\x81sica"),
    };
    // This load: Album One and itk_00000016 missing, their sidecars unreadable.
    std::vector<IntakeRecord> records = {previous[1], previous[3], previous[4]};
    UnreadableSidecars u = carryOverUnreadable(
        records,
        {parseError("/income/dump/Album One/.intake.json"),
         parseError("/income/shop/Loose Tracks/.intake.ITK_00000016.json")},
        previous);
    CHECK(records.size() == 5 && hasId(records, "itk_00000001") && hasId(records, "itk_00000016"),
          "both roots kept: a whole-directory sidecar by folder, a named one by id (case ignored)");
    CHECK(u.carriedIds.size() == 2 && u.carriedIds[0] == "itk_00000001" && u.carriedIds[1] == "itk_00000016",
          "the carried ids, in error order");
    CHECK(u.directories.size() == 2 && u.directories[0] == "/income/dump/Album One" &&
              u.directories[1] == "/income/shop/Loose Tracks",
          "the folders of the unreadable sidecars");
    CHECK(records[3].status == IntakeStatus::Resolved && records[3].rootPath == "/income/dump/Album One",
          "the last record itself");

    g_context = "carry-over-present";
    records = {previous[0], previous[1]};
    u = carryOverUnreadable(records, {parseError("/income/dump/Album One/.intake.json")}, previous);
    CHECK(records.size() == 2 && u.carriedIds.empty() && u.directories.size() == 1,
          "a root the load has is not added twice; its folder still counts");

    g_context = "carry-over-ignored";
    records = {};
    u = carryOverUnreadable(records,
                            {parseError("/income/dump/Album One/.intake.json", "E_INTERNAL"),
                             parseError("/income/dump/Album One/.intake-tmp-1"),
                             parseError("/income/dump/Album One/notes.txt"), parseError("relative/.intake.json")},
                            previous);
    CHECK(records.empty() && u.carriedIds.empty() && u.directories.empty(),
          "other codes, non-sidecar names and relative paths are left alone");
    CliError noPath = parseError("/income/dump/Album One/.intake.json");
    noPath.hasPath = false;
    u = carryOverUnreadable(records, {noPath}, previous);
    CHECK(records.empty() && u.directories.empty(), "an E_PARSE without a path is left alone");
    u = carryOverUnreadable(records, {parseError("/income/dump/Album Nine/.intake.json")}, previous);
    CHECK(records.empty() && u.directories.size() == 1, "no previous record there (a first load): nothing kept");

    g_context = "carry-over-keys";
    records = {};
    u = carryOverUnreadable(records,
                            {parseError("/income/dump//M\xC3\xBAsica/.intake.json"),
                             parseError("/income/shop/Loose Tracks/.intake.itk_0000001.json")},
                            previous);
    CHECK(records.size() == 1 && records[0].id == "itk_00000020",
          "folders compare as path keys (NFC, '//'); a shorter id is another root");
}

static std::shared_ptr<const IntakeSnapshot> keyedSnapshot(std::vector<IntakeRecord> records,
                                                           const MountAliases &aliases) {
    applyMountAliases(records, aliases);
    return IntakeSnapshot::build(std::move(records), {});
}

static void testRemountChangesRows() {
    g_context = "remount-diff";
    const MountEntry lan{"/Volumes/share", "//user@host-a/share", "smbfs"};
    const MountEntry vpn{"/Volumes/share-1", "//user@host-b/share", "smbfs"};
    const MountEntry backup{"/Volumes/backup", "//user@host-a/backup", "smbfs"};
    const std::vector<IntakeRecord> roots = {record("itk_00000001", "/Volumes/share/income/a"),
                                             record("itk_00000002", "/Users/someone/income/b")};
    auto shareOnly = MountAliases::build({lan});
    auto withBackup = MountAliases::build({lan, backup});
    auto both = MountAliases::build({lan, vpn});
    auto none = MountAliases::build({});
    auto s0 = keyedSnapshot(roots, *shareOnly);

    CHECK(!remountChangesRows(*s0, *shareOnly, *keyedSnapshot(roots, *withBackup), *withBackup),
          "a share holding no root mounts: no row changes");
    CHECK(!remountChangesRows(*keyedSnapshot(roots, *withBackup), *withBackup, *s0, *shareOnly),
          "nor when it unmounts");

    auto s1 = keyedSnapshot(roots, *both);
    CHECK(rendersAlike(*s0, *s1), "a second mount point of the roots' share keeps the root keys");
    CHECK(remountChangesRows(*s0, *shareOnly, *s1, *both),
          "but rows under the new mount point start matching: changed (item side only)");
    CHECK(remountChangesRows(*s1, *both, *s0, *shareOnly), "and stop matching when it goes");

    auto raw = keyedSnapshot(roots, *none);
    CHECK(remountChangesRows(*s0, *shareOnly, *raw, *none), "the roots' share unmounting: root keys change");
    CHECK(remountChangesRows(*raw, *none, *s0, *shareOnly), "and mounting again");

    std::vector<IntakeRecord> above = {record("itk_00000003", "/Volumes")};
    CHECK(remountChangesRows(*keyedSnapshot(above, *shareOnly), *shareOnly, *keyedSnapshot(above, *withBackup),
                             *withBackup),
          "a root above a changed mount point: its rows under that mount change");
    std::vector<IntakeRecord> cased = {record("itk_00000004", "/VOLUMES")};
    CHECK(remountChangesRows(*keyedSnapshot(cased, *shareOnly), *shareOnly, *keyedSnapshot(cased, *withBackup),
                             *withBackup),
          "the path test ignores ASCII case (conservative)");

    std::vector<IntakeRecord> local = {record("itk_00000005", "/Users/someone/income/c")};
    CHECK(!remountChangesRows(*keyedSnapshot(local, *none), *none, *keyedSnapshot(local, *both), *both),
          "local roots only: shares mounting change no row");
    CHECK(!remountChangesRows(*IntakeSnapshot::empty(), *none, *IntakeSnapshot::empty(), *both),
          "no roots: no row changes");
    std::vector<IntakeRecord> unusable = {record("itk_00000006", "relative/path")};
    CHECK(!remountChangesRows(*keyedSnapshot(unusable, *none), *none, *keyedSnapshot(unusable, *both), *both),
          "a root with no usable key matches nothing");

    std::vector<IntakeRecord> visual = roots;
    visual[1].status = IntakeStatus::Proposed;
    CHECK(remountChangesRows(*s0, *shareOnly, *keyedSnapshot(visual, *withBackup), *withBackup),
          "snapshots that do not render alike always count");
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

static void testStatusDisplay() {
    g_context = "status-display";
    const std::string dash = "\xE2\x80\x94";
    LoaderStatus s;
    s.state = LoaderState::NotConfigured;
    StatusDisplay d = statusDisplay(s);
    CHECK(d.state == "Not configured: set the CLI path" && d.cliVersion == dash && d.roots == dash &&
              d.lastError == "none" && d.tone == StatusTone::Neutral,
          "not configured: unknown version and roots, no error");
    s.state = LoaderState::Loading;
    CHECK(statusDisplay(s).state == "Loading\xE2\x80\xA6" && statusDisplay(s).roots == dash, "loading");

    s.state = LoaderState::Ready;
    s.cliVersion = "0.3.0";
    s.roots = 16;
    d = statusDisplay(s);
    CHECK(d.state == "Active" && d.cliVersion == "0.3.0" && d.roots == "16" && d.lastError == "none" &&
              d.tone == StatusTone::Good,
          "active");
    s.partialErrors = 2;
    s.error = "Unreadable sidecar (+1 more)";
    d = statusDisplay(s);
    CHECK(d.state == "Active" && d.tone == StatusTone::Warning &&
              d.lastError == "2 errors in the last load: Unreadable sidecar (+1 more)",
          "active after a partial load: a warning with the errors");
    s.partialErrors = 0;

    s.state = LoaderState::Stale;
    s.error = "status: Intake CLI timed out";
    d = statusDisplay(s);
    CHECK(d.state == "Active, last refresh failed" && d.lastError == "status: Intake CLI timed out" &&
              d.roots == "16" && d.tone == StatusTone::Warning,
          "stale: still active, with the error");

    s.state = LoaderState::Inert;
    s.error = "unsupported intake CLI (schema unsupported: schema 2, supported 1)";
    d = statusDisplay(s);
    CHECK(d.state == "Inactive: unsupported intake CLI (schema unsupported: schema 2, supported 1)" &&
              d.tone == StatusTone::Error,
          "inert: inactive with the reason");

    s.state = LoaderState::Failed;
    s.roots = 0;
    s.error = "status: Intake CLI internal error";
    d = statusDisplay(s);
    CHECK(d.state == "Inactive: the first load failed" && d.lastError == "status: Intake CLI internal error" &&
              d.roots == dash && d.tone == StatusTone::Error,
          "failed first load: inactive");
    s.state = LoaderState::Stopped;
    CHECK(statusDisplay(s).state == "Stopped", "stopped");

    s = LoaderStatus();
    s.state = LoaderState::Ready;
    CHECK(statusDisplay(s).cliVersion == dash, "a CLI without a version string");
}

static void testIncomeDisplay() {
    g_context = "income-display";
    LoaderStatus s;
    s.state = LoaderState::Ready;
    s.incomeOffered = true;
    s.incomeFolders = {{"dump", "/fixture/income/dump", true}, {"offline", "/fixture/income/offline", false}};
    s.rootFolders = {"/fixture/income/dump"};
    IncomeDisplay d = incomeDisplay(s);
    CHECK(d.fromCli && d.rows.size() == 2 && d.rows[0].name == "dump" && d.rows[0].exists &&
              d.rows[1].path == "/fixture/income/offline" && !d.rows[1].exists && d.note == "As listed by the CLI.",
          "income listed by the CLI, the missing folder marked");
    s.incomeError = "E_INTERNAL: fixture failure";
    d = incomeDisplay(s);
    CHECK(d.fromCli && d.rows.size() == 2 && d.note.find("listing them again failed: E_INTERNAL") != std::string::npos,
          "a failed income call after a good one: the earlier list, the failure named");
    s.incomeFolders.clear();
    d = incomeDisplay(s);
    CHECK(d.fromCli && d.rows.empty() &&
              d.note == "The CLI could not list the income folders: E_INTERNAL: fixture failure",
          "a failed income call with no good one: the failure, not an empty answer");
    s.incomeError.clear();
    CHECK(incomeDisplay(s).rows.empty() && incomeDisplay(s).note == "The CLI lists no income folders.",
          "the CLI lists none: no fallback to the roots");

    s.incomeOffered = false;
    s.rootFolders = {"/fixture/income/dump", "/fixture/income/shop"};
    d = incomeDisplay(s);
    CHECK(!d.fromCli && d.rows.size() == 2 && d.rows[1].path == "/fixture/income/shop" && d.rows[1].exists &&
              d.rows[1].name.empty() && d.note.find("cannot list income folders") != std::string::npos,
          "without an income command: the roots' folders");
    s.rootFolders.clear();
    CHECK(incomeDisplay(s).note == "No releases loaded.", "nothing loaded");
    s.state = LoaderState::Loading;
    CHECK(incomeDisplay(s).note == "Loading\xE2\x80\xA6", "loading");
    s.state = LoaderState::NotConfigured;
    s.incomeOffered = true;
    s.incomeFolders = {{"dump", "/fixture/income/dump", true}};
    CHECK(incomeDisplay(s).rows.empty() && incomeDisplay(s).note == "No CLI is running.",
          "not configured: nothing listed");
}

static void testCliTestSummary() {
    g_context = "cli-test-summary";
    VersionGateResult pass;
    pass.verdict = GateVerdict::Pass;
    pass.info.cli = "0.3.0";
    pass.info.hasCommands = true;
    pass.info.commands = {"version", "status", "income"};
    CliTestSummary t = cliTestSummary(result(CliOutcome::Ok), pass);
    CHECK(t.ok && t.text == "CLI 0.3.0, schema 1, 3 commands", "a passing CLI with a commands list");
    pass.info.hasCommands = false;
    pass.info.commands.clear();
    pass.info.cli = "0.2.1";
    CHECK(cliTestSummary(result(CliOutcome::Ok), pass).text == "CLI 0.2.1, schema 1", "no commands list");

    VersionGateResult fail;
    fail.verdict = GateVerdict::SchemaUnsupported;
    fail.detail = "schema 2, supported 1";
    fail.info.cli = "0.3.0";
    t = cliTestSummary(result(CliOutcome::Ok), fail);
    CHECK(!t.ok && t.text == "Unsupported CLI: schema 2, supported 1, cli 0.3.0", "a failed gate");

    t = cliTestSummary(hostNoCli("the intake CLI path must be absolute: relative/intake"), VersionGateResult());
    CHECK(!t.ok && t.text.rfind("Failed: ", 0) == 0 && t.text.find("relative/intake") != std::string::npos,
          "E_NO_CLI: failed, with the reason");
    t = cliTestSummary(result(CliOutcome::Failed, {"E_NO_RULES"}), VersionGateResult());
    CHECK(!t.ok && t.text.find("no rules dir") != std::string::npos, "a CLI error");
    CHECK(!cliTestSummary(result(CliOutcome::Cancelled), pass).ok &&
              cliTestSummary(result(CliOutcome::Cancelled), pass).text == "Cancelled",
          "cancelled at quit");
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
        testCarryOverUnreadable();
        testRemountChangesRows();
        testStatusLine();
        testStatusDisplay();
        testIncomeDisplay();
        testCliTestSummary();
        testDecorStats();
    }
    TEST_MAIN_END();
}
