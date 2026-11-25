//
//  IntakeAutoScanResultTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeAutoScanResult (B12): the scan reply read leniently
//  (nil, not an array, blocks that are no objects, missing or mistyped
//  `written` and `kept`, rows without a string id, several blocks), and the
//  outcome of each envelope outcome (ok with and without counts, partial,
//  failed, E_NO_CLI, the cap kill, cancelled): the scheduler exit, the Info
//  line, the status bar's result and count (also through ActivityModel's
//  texts). The start and 10 s lines, and the errors text (none, a path, an
//  empty msg, more than three). The auto-propose after a scan
//  (proposeAfterScan, PLAN-B12 scope addition 1): only resolved written
//  roots (new, other and missing statuses skipped with one line), never a
//  kept root, never the income folder itself, per scan outcome, order and
//  repeats, the roots it hands on, and its start and 10 s lines. Envelopes
//  from CLI-shaped JSON through parseEnvelope. Synthetic names only.
//
// TEST_DEPS: src/Core/IntakeEnvelope.mm src/Core/IntakeActivity.mm src/Core/IntakePath.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeAutoScanResult.h"
#include "TestHarness.h"

#include <initializer_list>
#include <string>
#include <vector>

using namespace intake;

namespace {

const char *const kIncome = "/Users/x/Music/fixture-income";

// One `scan --json` block as CLI 0.3.0 prints it (commands.ts ScanBlock).
std::string block(const std::string &written, const std::string &kept) {
    return std::string("{\"income\":\"local\",\"path\":\"") + kIncome + "\",\"dry_run\":false,\"archives\":[]" +
           (written.empty() ? std::string() : ",\"written\":" + written) +
           (kept.empty() ? std::string() : ",\"kept\":" + kept) + "}";
}

std::string row(const char *id, const char *status, const char *folder) {
    return std::string("{\"id\":\"") + id + "\",\"root_path\":\"" + kIncome + "/" + folder + "\",\"sidecar_path\":\"" +
           kIncome + "/" + folder + "/.intake.json\",\"status\":\"" + status +
           "\",\"needs_review\":false,\"confidence\":0.9,\"tier_eligible\":\"hq\",\"virtual\":false,"
           "\"singles\":false,\"albumartist\":\"Fixture Artist\",\"album\":\"Fixture Album\"}";
}

CliResult result(const std::string &stdoutText, int exitCode, double seconds = 12.34) {
    CliResult r;
    r.command = CliCommand::Scan;
    r.commandClass = CommandClass::Mutating;
    r.envelope = parseEnvelope(stdoutText, exitCode);
    r.process.elapsedSeconds = seconds;
    return r;
}

CliResult hostResult(EnvelopeResult envelope, double seconds = 900.0) {
    CliResult r;
    r.command = CliCommand::Scan;
    r.commandClass = CommandClass::Mutating;
    r.envelope = std::move(envelope);
    r.process.elapsedSeconds = seconds;
    return r;
}

CliError err(const char *code, const char *msg, const char *path = nullptr) {
    CliError e;
    e.code = code;
    e.msg = msg;
    if (path != nullptr) {
        e.path = path;
        e.hasPath = true;
    }
    return e;
}

// The status bar's line for a scan of "local" ended with `outcome`.
std::string resultLine(const AutoScanOutcome &outcome) {
    ActivityModel m;
    m.begin("k", ActivityKind::Scan, 0, "local", 0);
    m.end("k", outcome.activity, 1, outcome.newRoots);
    const std::optional<ActivityLine> line = m.line(1);
    return line ? line->text : std::string();
}

bool idsAre(const std::vector<std::string> &got, std::initializer_list<const char *> want) {
    if (got.size() != want.size()) return false;
    size_t i = 0;
    for (const char *w : want) {
        if (got[i++] != w) return false;
    }
    return true;
}

ScanWrittenRoot written(const char *id, const char *status, const std::string &rootPath = std::string()) {
    return ScanWrittenRoot{id, rootPath.empty() ? std::string(kIncome) + "/" + id : rootPath, status};
}

ScanReply replyOf(std::vector<ScanWrittenRoot> rows) {
    ScanReply r;
    r.counted = true;
    r.writtenCount = rows.size();
    r.written = std::move(rows);
    return r;
}

// --- the reply ---

void testReply() {
    g_context = "reply";
    ScanReply r = readScanReply(nil);
    CHECK(!r.counted && r.writtenCount == 0 && r.keptCount == 0 && r.written.empty(), "nil: nothing known");
    r = readScanReply(@{@"written" : @[]});
    CHECK(!r.counted, "an object instead of an array of blocks: nothing known");
    r = readScanReply(@[ @"x", @3, [NSNull null] ]);
    CHECK(!r.counted, "blocks that are no objects add nothing");
    r = readScanReply(@[ @{@"income" : @"local"} ]);
    CHECK(!r.counted, "a block with neither member: nothing known");
    r = readScanReply(@[ @{@"written" : @"x", @"kept" : @{}} ]);
    CHECK(!r.counted, "mistyped members add nothing");

    r = readScanReply(@[ @{@"written" : @[], @"kept" : @[]} ]);
    CHECK(r.counted && r.writtenCount == 0 && r.keptCount == 0, "empty arrays: known, zero");

    r = readScanReply(@[
        @{
            @"written" : @[
                @{@"id" : @"itk_00000001", @"root_path" : @"/Users/x/Music/fixture-income/A", @"status" : @"resolved"},
                @{@"id" : @"itk_00000002"},
                @{@"root_path" : @"/Users/x/Music/fixture-income/C", @"status" : @"new"},
                @{@"id" : @7, @"status" : @"new"},
                @"itk_00000005",
            ],
            @"kept" : @[ @"/Users/x/Music/fixture-income/Old", @"/Users/x/Music/fixture-income/Older" ],
        },
        @{@"written" : @[ @{@"id" : @"itk_00000006", @"status" : @"new"} ]},
        @{@"kept" : @[ @"/Volumes/music/fixture-income/Kept" ]},
    ]);
    CHECK(r.counted, "known");
    CHECK_EQ(r.writtenCount, 6, "every row of every block's written counts, with or without an id");
    CHECK_EQ(r.keptCount, 3, "every block's kept");
    CHECK(r.written.size() == 3, "only rows with a string id are listed");
    CHECK(r.written.size() == 3 && r.written[0].id == "itk_00000001" &&
              r.written[0].rootPath == "/Users/x/Music/fixture-income/A" && r.written[0].status == "resolved",
          "id, root_path, status");
    CHECK(r.written.size() == 3 && r.written[1].id == "itk_00000002" && r.written[1].rootPath.empty() &&
              r.written[1].status.empty(),
          "missing members read as empty");
    CHECK(r.written.size() == 3 && r.written[2].id == "itk_00000006" && r.written[2].status == "new",
          "in order, across blocks");
}

// --- the outcome ---

void testOk() {
    g_context = "ok";
    const std::string json = "{\"ok\":true,\"data\":[" +
                             block("[" + row("itk_00000001", "resolved", "Fixture Artist - Fixture Album") + "," +
                                       row("itk_00000002", "new", "Fixture Artist - Second Album") + "]",
                                   "[\"" + std::string(kIncome) + "/Old Album\"]") +
                             "],\"errors\":[]}";
    AutoScanOutcome o = autoScanOutcome("local", result(json, 0));
    CHECK(o.exit == AutoScanExit::Finished, "exit 0: Finished");
    CHECK(o.line == "auto-scan: local done in 12.3 s: 2 new roots, 1 kept", "the done line with counts");
    CHECK(o.activity.succeeded && o.activity.reason.empty(), "succeeded");
    CHECK_EQ(o.newRoots, 2, "the count is the roots written");
    CHECK(o.reply.written.size() == 2 && o.reply.written[0].status == "resolved" &&
              o.reply.written[1].status == "new",
          "the written roots for the auto-propose");
    CHECK(resultLine(o) == "Scanned local: 2 new albums", "status bar: the albums it found");

    o = autoScanOutcome("local", result("{\"ok\":true,\"data\":[" +
                                            block("[" + row("itk_00000001", "new", "A") + "]", "[]") +
                                            "],\"errors\":[]}",
                                        0, 0.04));
    CHECK(o.line == "auto-scan: local done in 0.0 s: 1 new root, 0 kept", "one root, nothing kept");
    CHECK(resultLine(o) == "Scanned local: 1 new album", "status bar: one album");

    o = autoScanOutcome("local", result("{\"ok\":true,\"data\":[" + block("[]", "[\"/x/Old\"]") + "],\"errors\":[]}",
                                        0, 3.25));
    CHECK(o.line == "auto-scan: local done in 3.2 s: 0 new roots, 1 kept", "nothing new");
    CHECK(o.newRoots == 0 && resultLine(o) == "Scanned local", "status bar: no count when nothing is new");

    o = autoScanOutcome("p2p", result("{\"ok\":true,\"data\":{\"something\":1},\"errors\":[]}", 0, 61.0));
    CHECK(o.exit == AutoScanExit::Finished && o.line == "auto-scan: p2p done in 61.0 s",
          "a data shape not known: the line without counts");
    CHECK(o.activity.succeeded && o.newRoots == 0, "still succeeded, count 0");
    o = autoScanOutcome("p2p", result("{\"ok\":true,\"data\":null,\"errors\":[]}", 0, 1.0));
    CHECK(o.line == "auto-scan: p2p done in 1.0 s", "data null: no counts");
}

void testPartial() {
    g_context = "partial";
    const std::string json =
        "{\"ok\":false,\"data\":[" +
        block("[" + row("itk_00000001", "resolved", "A") + "]", "[]") +
        "],\"errors\":[{\"code\":\"E_ARCHIVE\",\"msg\":\"unpack failed\",\"path\":\"/Users/x/Music/fixture-income/a.zip\"}]}";
    const AutoScanOutcome o = autoScanOutcome("local", result(json, 1));
    CHECK(o.exit == AutoScanExit::Finished, "exit 1: Finished (the roots written are real)");
    CHECK(o.line == "auto-scan: local done in 12.3 s with errors: 1 new root, 0 kept; E_ARCHIVE: unpack failed "
                    "(/Users/x/Music/fixture-income/a.zip)",
          "done with errors: counts, then the errors");
    CHECK(!o.activity.succeeded && o.activity.reason == "E_ARCHIVE: unpack failed" && o.activity.detail == o.line,
          "status bar: failed, the first error without its path; the line as detail");
    CHECK(o.newRoots == 1 && o.reply.written.size() == 1, "the written roots are still read");
    CHECK(resultLine(o) == "Scan failed: E_ARCHIVE: unpack failed", "never the check icon with errors");

    const std::string noCounts =
        "{\"ok\":false,\"data\":[{\"income\":\"local\"}],\"errors\":[{\"code\":\"E_ARCHIVE_TOOL\",\"msg\":\"unar "
        "missing\",\"path\":null}]}";
    CHECK(autoScanOutcome("local", result(noCounts, 1)).line ==
              "auto-scan: local done in 12.3 s with errors: E_ARCHIVE_TOOL: unar missing",
          "with errors but no counts");
}

void testFailures() {
    g_context = "failures";
    const std::string json = "{\"ok\":false,\"data\":null,\"errors\":[{\"code\":\"E_NOT_FOUND\",\"msg\":\"income "
                             "path missing: local\",\"path\":\"/Users/x/Music/fixture-income\"}]}";
    AutoScanOutcome o = autoScanOutcome("local", result(json, 2));
    CHECK(o.exit == AutoScanExit::Finished, "exit 2: Finished (the scan ran)");
    CHECK(o.line == "auto-scan: local failed: E_NOT_FOUND: income path missing: local (/Users/x/Music/fixture-income)",
          "the failed line: code, message, path");
    CHECK(!o.activity.succeeded && o.activity.reason == "E_NOT_FOUND: income path missing: local",
          "status bar: the first error");
    CHECK(o.newRoots == 0 && !o.reply.counted, "no counts");
    CHECK(resultLine(o) == "Scan failed: E_NOT_FOUND: income path missing: local", "status bar text");

    o = autoScanOutcome("local", result("not json", 0));
    CHECK(o.exit == AutoScanExit::Refused, "E_NO_CLI (unparseable stdout): Refused");
    CHECK(o.line.rfind("auto-scan: local failed: E_NO_CLI: ", 0) == 0, "the failed line names E_NO_CLI");
    CHECK(!o.activity.succeeded && o.activity.reason.rfind("E_NO_CLI: ", 0) == 0, "status bar: E_NO_CLI");

    o = autoScanOutcome("local", hostResult(hostNoCli("cannot start the intake CLI (spawn): No such file")));
    CHECK(o.exit == AutoScanExit::Refused &&
              o.line == "auto-scan: local failed: E_NO_CLI: cannot start the intake CLI (spawn): No such file",
          "a host E_NO_CLI: Refused, its detail in the line");

    o = autoScanOutcome("share", hostResult(hostTimeout("still running at the hard cap; terminated")));
    CHECK(o.exit == AutoScanExit::CapKilled, "E_CLI_TIMEOUT (killed at the cap): CapKilled");
    CHECK(o.line == "auto-scan: share failed: E_CLI_TIMEOUT: still running at the hard cap; terminated",
          "the failed line");
    CHECK(!o.activity.succeeded && o.activity.reason == "stopped at the 15-minute cap", "status bar: the cap");

    EnvelopeResult cancelled;
    cancelled.outcome = CliOutcome::Cancelled;
    o = autoScanOutcome("local", hostResult(cancelled));
    CHECK(o.exit == AutoScanExit::Finished && o.line == "auto-scan: local cancelled", "cancelled");
    CHECK(!o.activity.succeeded && o.activity.reason == "cancelled", "status bar: cancelled");
}

// --- texts ---

void testTexts() {
    g_context = "texts";
    CHECK(autoScanStartLine("local", true) == "auto-scan: scanning income local (startup)", "startup");
    CHECK(autoScanStartLine("share", false) == "auto-scan: scanning income share (new files)", "new files");
    CHECK(autoScanBudgetLine("share") ==
              "auto-scan: share still running (E_CLI_TIMEOUT: no reply after 10 s; the scan continues)",
          "the 10 s line");

    CHECK(autoScanErrorsText({}).empty(), "no errors: empty");
    CHECK(autoScanErrorsText({err("E_ARCHIVE", "unpack failed", "/x/a.zip")}) == "E_ARCHIVE: unpack failed (/x/a.zip)",
          "code, msg, path");
    CHECK(autoScanErrorsText({err("E_INTERNAL", "")}) == "E_INTERNAL", "an empty msg: the code alone");
    CHECK(autoScanErrorsText({err("E_X", "", "/x")}) == "E_X (/x)", "an empty msg with a path");
    CHECK(autoScanErrorsText({err("E_A", "a"), err("E_B", "b"), err("E_C", "c")}) == "E_A: a; E_B: b; E_C: c",
          "three: all shown");
    CHECK(autoScanErrorsText({err("E_A", "a"), err("E_B", "b"), err("E_C", "c"), err("E_D", "d"), err("E_E", "e")}) ==
              "E_A: a; E_B: b; E_C: c (+2 more)",
          "five: three shown, then the rest counted");
}

// --- the auto-propose (scope addition 1) ---

void testProposeStatuses() {
    g_context = "propose-statuses";
    const ScanReply reply = replyOf({written("itk_00000001", "resolved"), written("itk_00000002", "new"),
                                     written("itk_00000003", "resolved"), written("itk_00000004", ""),
                                     written("itk_00000005", "proposed")});
    const ScanFollowUp next = proposeAfterScan("local", kIncome, CliOutcome::Ok, reply);
    CHECK(idsAre(next.propose, {"itk_00000001", "itk_00000003"}), "only the resolved roots, in the scan's order");
    CHECK(next.roots.size() == 2 && next.roots[0].id == "itk_00000001" &&
              next.roots[0].rootPath == std::string(kIncome) + "/itk_00000001" &&
              next.roots[0].status == IntakeStatus::Resolved && next.roots[0].targetPath.empty() &&
              next.roots[1].id == "itk_00000003",
          "their roots: root_path as the CLI wrote it, status resolved (the error baseline), no target");
    CHECK(idsAre(next.skipped, {"itk_00000002 (new)", "itk_00000004 (no status)", "itk_00000005 (proposed)"}),
          "new, no status and any other status are skipped");
    CHECK(next.skippedLine == "auto-scan: local: no propose for 3 roots: itk_00000002 (new), itk_00000004 (no "
                              "status), itk_00000005 (proposed)",
          "one Debug line for the skipped");

    const ScanFollowUp one = proposeAfterScan("p2p", kIncome, CliOutcome::Ok, replyOf({written("itk_00000002", "new")}));
    CHECK(one.propose.empty() && one.roots.empty() &&
              one.skippedLine == "auto-scan: p2p: no propose for 1 root: itk_00000002 (new)",
          "only a new root: nothing to propose, singular");

    const ScanFollowUp clean =
        proposeAfterScan("local", kIncome, CliOutcome::Ok, replyOf({written("itk_00000001", "resolved")}));
    CHECK(idsAre(clean.propose, {"itk_00000001"}) && clean.skipped.empty() && clean.skippedLine.empty(),
          "nothing skipped: no line");
    CHECK(proposeAfterScan("local", kIncome, CliOutcome::Ok, replyOf({written("itk_00000001", "Resolved")}))
              .propose.empty(),
          "the status must be exactly \"resolved\"");
    CHECK(proposeAfterScan("local", kIncome, CliOutcome::Ok, ScanReply()).propose.empty() &&
              proposeAfterScan("local", kIncome, CliOutcome::Ok, ScanReply()).skippedLine.empty(),
          "nothing written: nothing, no line");
}

void testProposeOutcomes() {
    g_context = "propose-outcomes";
    const ScanReply reply = replyOf({written("itk_00000001", "resolved"), written("itk_00000002", "resolved")});
    CHECK(proposeAfterScan("local", kIncome, CliOutcome::Ok, reply).propose.size() == 2, "exit 0: both");
    CHECK(proposeAfterScan("local", kIncome, CliOutcome::Partial, reply).propose.size() == 2,
          "exit 1: the roots it wrote are real (its errors name archives, not roots)");
    const CliOutcome nothing[] = {CliOutcome::Failed, CliOutcome::NoCli, CliOutcome::Timeout, CliOutcome::Cancelled};
    int none = 0;
    for (CliOutcome o : nothing) {
        // Even with a reply (it cannot happen: autoScanOutcome reads none),
        // the outcome decides first.
        const ScanFollowUp next = proposeAfterScan("local", kIncome, o, reply);
        if (next.propose.empty() && next.skipped.empty() && next.skippedLine.empty()) none++;
    }
    CHECK_EQ(none, 4, "exit 2, E_NO_CLI, E_CLI_TIMEOUT and cancelled propose nothing");
}

void testProposeIncomeFolder() {
    g_context = "propose-income-folder";
    const ScanReply reply = replyOf({written("itk_00000001", "resolved", kIncome),
                                     written("itk_00000002", "resolved", std::string(kIncome) + "/"),
                                     written("itk_00000003", "resolved", std::string(kIncome) + "/Fixture Album"),
                                     written("itk_00000004", "new", kIncome)});
    const ScanFollowUp next = proposeAfterScan("local", kIncome, CliOutcome::Ok, reply);
    CHECK(idsAre(next.propose, {"itk_00000003"}), "a root in a subfolder is proposed");
    CHECK(idsAre(next.skipped, {"itk_00000001 (the income folder itself)", "itk_00000002 (the income folder itself)",
                                "itk_00000004 (new)"}),
          "a root that is the income folder (also with a trailing slash) is skipped; a new one there says new");
    CHECK(idsAre(proposeAfterScan("local", std::string(kIncome) + "/", CliOutcome::Ok,
                                  replyOf({written("itk_00000001", "resolved", kIncome)}))
                     .propose,
                 {}),
          "the income path with a trailing slash matches too");
    CHECK(idsAre(proposeAfterScan("local", "", CliOutcome::Ok, replyOf({written("itk_00000001", "resolved", kIncome)}))
                     .propose,
                 {"itk_00000001"}),
          "no income path known: no guard");
    CHECK(idsAre(proposeAfterScan("share", "/Volumes/music/fixture-income", CliOutcome::Ok,
                                  replyOf({written("itk_00000005", "resolved", "/Volumes/music/fixture-income"),
                                           written("itk_00000006", "resolved",
                                                   "/Volumes/music/fixture-income.other")}))
                     .propose,
                 {"itk_00000006"}),
          "on a share too, and a sibling folder that shares the prefix is not the income");
}

void testProposeOrder() {
    g_context = "propose-order";
    const ScanReply reply = replyOf({written("itk_00000009", "resolved"), written("itk_00000002", "resolved"),
                                     written("itk_00000009", "resolved"), written("itk_00000002", "new")});
    const ScanFollowUp next = proposeAfterScan("local", kIncome, CliOutcome::Ok, reply);
    CHECK(idsAre(next.propose, {"itk_00000009", "itk_00000002"}) && next.roots.size() == 2 && next.skipped.empty(),
          "the scan's order, a repeated id counted once (its first row decides)");
}

// As Integration calls it: autoScanOutcome on the scan's envelope first.
void testProposeThroughOutcome() {
    g_context = "propose-through-outcome";
    const std::string reviewRow =
        "{\"id\":\"itk_00000003\",\"root_path\":\"" + std::string(kIncome) +
        "/Review\",\"status\":\"resolved\",\"needs_review\":true,\"confidence\":0.6}";
    const std::string json = "{\"ok\":true,\"data\":[" +
                             block("[" + row("itk_00000001", "resolved", "Fixture Artist - Fixture Album") + "," +
                                       row("itk_00000002", "new", "Fixture Artist - Second Album") + "," + reviewRow +
                                       ",{\"status\":\"resolved\"}]",
                                   "[\"" + std::string(kIncome) + "/Fixture Artist - Old Album\"]") +
                             "],\"errors\":[]}";
    const CliResult r = result(json, 0);
    const AutoScanOutcome o = autoScanOutcome("local", r);
    const ScanFollowUp next = proposeAfterScan("local", kIncome, r.envelope.outcome, o.reply);
    CHECK(idsAre(next.propose, {"itk_00000001", "itk_00000003"}),
          "the resolved roots written, one that needs review included");
    CHECK(next.roots.size() == 2 && next.roots[0].rootPath == std::string(kIncome) + "/Fixture Artist - Fixture Album",
          "root_path from the reply");
    CHECK(idsAre(next.skipped, {"itk_00000002 (new)"}), "the new one skipped");
    for (const MutationRoot &m : next.roots) {
        CHECK(m.rootPath.find("Old Album") == std::string::npos, "a kept root is never proposed");
    }
    CHECK(o.newRoots == 4 && next.propose.size() == 2, "a row without an id counts as written but cannot be named");

    const std::string partial =
        "{\"ok\":false,\"data\":[" + block("[" + row("itk_00000001", "resolved", "A") + "]", "[]") +
        "],\"errors\":[{\"code\":\"E_ARCHIVE\",\"msg\":\"unpack failed\",\"path\":\"" + std::string(kIncome) +
        "/A\"}]}";
    const CliResult p = result(partial, 1);
    CHECK(idsAre(proposeAfterScan("local", kIncome, p.envelope.outcome, autoScanOutcome("local", p).reply).propose,
                 {"itk_00000001"}),
          "exit 1: proposed, even when an error's path is the root's folder");

    const std::string failed = "{\"ok\":false,\"data\":null,\"errors\":[{\"code\":\"E_NO_RULES\",\"msg\":\"no income "
                               "folders configured\",\"path\":null}]}";
    const CliResult f = result(failed, 2);
    CHECK(proposeAfterScan("local", kIncome, f.envelope.outcome, autoScanOutcome("local", f).reply).propose.empty(),
          "exit 2: nothing");
}

void testProposeTexts() {
    g_context = "propose-texts";
    CHECK(autoScanProposeStartLine("local", {"itk_00000001", "itk_00000003"}) ==
              "propose: starting after auto-scan of local for 2 roots: itk_00000001 itk_00000003",
          "the start line");
    CHECK(autoScanProposeStartLine("p2p", {"itk_00000001"}) ==
              "propose: starting after auto-scan of p2p for 1 root: itk_00000001",
          "one root");
    CHECK(autoScanProposeBudgetLine("share") == "propose: still running after auto-scan of share (E_CLI_TIMEOUT: no "
                                                "reply after 10 s; the propose continues)",
          "the 10 s line");
}

} // anonymous namespace

int main(void) {
    @autoreleasepool {
        testReply();
        testOk();
        testPartial();
        testFailures();
        testTexts();
        testProposeStatuses();
        testProposeOutcomes();
        testProposeIncomeFolder();
        testProposeOrder();
        testProposeThroughOutcome();
        testProposeTexts();
    }
    TEST_MAIN_END();
}
