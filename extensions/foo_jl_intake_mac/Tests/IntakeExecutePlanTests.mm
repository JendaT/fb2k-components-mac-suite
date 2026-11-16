//
//  IntakeExecutePlanTests.mm
//  foo_jl_intake_mac
//
//  IntakeExecutePlan (PLAN.md B8): the execute --dry-run reply with every
//  field optional, the plan (placeable and excluded roots, refused roots
//  only in errors[]), the sheet texts (rows with missing parts, the cap of
//  10 and "and N more"), and a real dry run against the mock.
//
// TEST_DEPS: src/Core/IntakeEnvelope.mm src/Core/IntakeMutationResult.mm src/Core/IntakeErrorMap.mm
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeCommandArgs.mm src/Core/IntakeSemver.mm
// TEST_DEPS: src/Core/IntakeSettingsParse.mm src/Core/IntakeLog.mm src/Core/IntakeActionTable.mm
// TEST_DEPS: src/Core/IntakeCapabilities.mm src/Core/IntakeReviewRule.mm src/Core/IntakeCliRunner.mm
// TEST_DEPS: src/Core/IntakeProcess.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeCliRunner.h"
#include "../src/Core/IntakeExecutePlan.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <string>
#include <vector>

using namespace intake;

namespace {

const std::string kArrow = " \xE2\x86\x92 ";
const std::string kDash = " \xE2\x80\x93 ";

std::vector<std::string> v(std::initializer_list<std::string> items) {
    return std::vector<std::string>(items);
}

id json(const char *text) {
    return [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:text length:strlen(text)]
                                           options:NSJSONReadingFragmentsAllowed
                                             error:nil];
}

ActionRoot root(const char *id, const char *artist, const char *album, const char *path = "") {
    ActionRoot r;
    r.id = id;
    r.albumartist = artist;
    r.album = album;
    r.rootPath = path;
    r.status = IntakeStatus::Approved;
    return r;
}

DryRunRow row(const char *id, const char *target, long long files, long long shadows) {
    DryRunRow r;
    r.id = id;
    r.targetPath = target;
    r.hasFiles = files >= 0;
    r.files = files;
    r.hasShadows = shadows >= 0;
    r.skippedShadows = shadows;
    return r;
}

} // namespace

static void testParseRows() {
    g_context = "parse-rows";
    DryRunParse all = parseDryRunRows(json(
        R"([{"id":"itk_00000010","root_path":"/income/dump/A","target_path":"/lib/A","dry_run":true,"files":2,"artifacts":1,"skipped_shadows":3}])"));
    CHECK(all.isArray && all.rows.size() == 1 && all.skipped == 0, "one row");
    const DryRunRow &r = all.rows[0];
    CHECK(r.id == "itk_00000010" && r.rootPath == "/income/dump/A" && r.targetPath == "/lib/A", "id, root_path, target_path");
    CHECK(r.hasFiles && r.files == 2 && r.hasArtifacts && r.artifacts == 1 && r.hasShadows && r.skippedShadows == 3,
          "files, artifacts, skipped_shadows");

    DryRunParse bare = parseDryRunRows(json(R"([{"id":"itk_00000010"}])"));
    CHECK(bare.rows.size() == 1 && bare.rows[0].rootPath.empty() && bare.rows[0].targetPath.empty() &&
              !bare.rows[0].hasFiles && !bare.rows[0].hasArtifacts && !bare.rows[0].hasShadows,
          "every field but id is optional");

    DryRunParse odd = parseDryRunRows(json(
        R"([{"id":"itk_00000010","target_path":null,"files":"2","artifacts":-1,"skipped_shadows":true},)"
        R"({"id":"itk_0000000b","files":2.5},{"root_path":"/x"},{"id":7},"text",{"id":"itk_00000010","files":9}])"));
    CHECK(odd.rows.size() == 2 && odd.skipped == 4, "rows without a usable id, and a repeated id, are skipped");
    CHECK(odd.rows[0].targetPath.empty() && !odd.rows[0].hasFiles && !odd.rows[0].hasArtifacts &&
              !odd.rows[0].hasShadows,
          "a null target, a string count, a negative count and a boolean count are missing");
    CHECK(!odd.rows[1].hasFiles, "a fractional count is missing");
    CHECK(!parseDryRunRows(json(R"({"id":"itk_00000010"})")).isArray && !parseDryRunRows(nil).isArray,
          "data that is not an array: nothing");
    CHECK(parseDryRunRows(json("[]")).isArray && parseDryRunRows(json("[]")).rows.empty(), "empty data: no rows");
}

static void testPlan() {
    g_context = "plan";
    std::vector<ActionRoot> roots = {root("itk_00000010", "Fixture Artist", "Approved Album", "/income/dump/Approved"),
                                     root("itk_0000000d", "Fixture Artist", "Proposed Album", "/income/dump/Proposed"),
                                     root("itk_00000015", "Various Artists", "Test Compilation", "/income/dump/VA")};
    // Partial: one row, one refused root (by its folder), one not mentioned.
    EnvelopeResult partial = parseEnvelope(
        R"({"ok":false,"data":[{"id":"itk_00000010","root_path":"/income/dump/Approved","target_path":"/lib/A","dry_run":true,"files":2,"artifacts":0,"skipped_shadows":0}],)"
        R"("errors":[{"code":"E_BAD_STATUS","msg":"cannot execute from status proposed","path":"/income/dump/Proposed"}]})",
        1);
    ExecutePlan p = planExecute(roots, partial);
    CHECK(placeableIds(p) == v({"itk_00000010"}) && p.rows.size() == 1 && p.rows[0].targetPath == "/lib/A",
          "the root with a row is placeable");
    CHECK(p.excluded.size() == 2 && p.excluded[0].id == "itk_0000000d" && p.excluded[1].id == "itk_00000015",
          "the others are excluded, in selection order");
    CHECK(p.excludedWhy.size() == 2 &&
              p.excludedWhy[0] == "Not allowed in the current state: cannot execute from status proposed" &&
              p.excludedWhy[1] == "not listed by the dry run",
          "a refused root shows its error (without the prefix), an unlisted one says so");
    CHECK(p.outcome.rootErrors.size() == 1 && p.outcome.rootErrors[0].first == "itk_0000000d" &&
              p.outcome.rootErrors[0].second ==
                  "execute dry run: Not allowed in the current state: cannot execute from status proposed",
          "the tooltip names the dry run");
    CHECK(p.outcome.isError &&
              p.outcome.consoleLine ==
                  "execute dry run: done for 1 of 3 roots; Not allowed in the current state: cannot execute from status "
                  "proposed (/income/dump/Proposed)",
          "the console line names the dry run");

    // Refused roots only in errors[]: exit 2, data null.
    EnvelopeResult failed = parseEnvelope(
        R"({"ok":false,"data":null,"errors":[{"code":"E_TARGET_EXISTS","msg":"target path already exists","path":"/lib/A"}]})",
        2);
    ExecutePlan none = planExecute({roots[0]}, failed);
    CHECK(none.placeable.empty() && none.excluded.size() == 1, "nothing placeable when every root was refused");
    CHECK(none.excludedWhy[0] == "Target folder already exists: target path already exists (/lib/A)",
          "a refusal whose path is the target: shown with its path");
    CHECK(none.outcome.consoleLine ==
              "execute dry run failed for 1 root: Target folder already exists: target path already exists (/lib/A)",
          "execute dry run failed for 1 root: ...");

    // Ok but empty: nothing placeable, nothing refused.
    ExecutePlan empty = planExecute({roots[0]}, parseEnvelope(R"({"ok":true,"data":[],"errors":[]})", 0));
    CHECK(empty.placeable.empty() && empty.excludedWhy == v({"not listed by the dry run"}) &&
              empty.outcome.rootErrors.empty() && !empty.outcome.isError,
          "empty data: nothing placeable, no error");

    // Host-synthesized failure.
    ExecutePlan noCli = planExecute({roots[0]}, hostNoCli("spawn failed"));
    CHECK(noCli.placeable.empty() && noCli.excludedWhy[0] == "Intake CLI not available: spawn failed",
          "E_NO_CLI: nothing placeable, the reason shown");

    // A row for a root the menu did not capture is ignored; repeats once.
    ExecutePlan stray = planExecute({roots[0], roots[0]}, parseEnvelope(
        R"({"ok":true,"data":[{"id":"itk_000000ff"},{"id":"itk_00000010"}],"errors":[]})", 0));
    CHECK(placeableIds(stray) == v({"itk_00000010"}) && stray.excluded.empty(), "a stray row is ignored, a root counted once");
}

static void testSheetRows() {
    g_context = "sheet-rows";
    ActionRoot full = root("itk_00000010", "Fixture Artist", "Approved Album", "/income/dump/Fixture Artist - Approved Album");
    CHECK(executeSheetRow(full, row("itk_00000010", "/lib/A/Fixture Artist - 2026 - Approved Album", 2, 0)) ==
              "Fixture Artist" + kDash + "Approved Album" + kArrow +
                  "/lib/A/Fixture Artist - 2026 - Approved Album (2 files, 0 shadows skipped)",
          "artist – album → target (n files, k shadows skipped)");
    CHECK(executeSheetRow(full, row("itk_00000010", "/lib/A", 1, 1)) ==
              "Fixture Artist" + kDash + "Approved Album" + kArrow + "/lib/A (1 file, 1 shadow skipped)",
          "singular counts");
    CHECK(executeSheetRow(full, row("itk_00000010", "/lib/A", 3, -1)) ==
              "Fixture Artist" + kDash + "Approved Album" + kArrow + "/lib/A (3 files)",
          "no shadow count: left out");
    CHECK(executeSheetRow(full, row("itk_00000010", "/lib/A", -1, 2)) ==
              "Fixture Artist" + kDash + "Approved Album" + kArrow + "/lib/A (2 shadows skipped)",
          "no file count: left out");
    CHECK(executeSheetRow(full, row("itk_00000010", "/lib/A", -1, -1)) ==
              "Fixture Artist" + kDash + "Approved Album" + kArrow + "/lib/A",
          "no counts: no parenthesis");
    CHECK(executeSheetRow(full, row("itk_00000010", "", 2, 0)) ==
              "Fixture Artist" + kDash + "Approved Album (2 files, 0 shadows skipped)",
          "no target: no arrow");
    ActionRoot noArtist = root("itk_00000010", "", "Approved Album", "/income/dump/X");
    CHECK(executeSheetRow(noArtist, row("itk_00000010", "/lib/A", 2, -1)) == "Approved Album" + kArrow + "/lib/A (2 files)",
          "no artist: the album alone");
    ActionRoot noAlbum = root("itk_00000010", "Fixture Artist E", "", "/income/shop/Loose Tracks");
    CHECK(executeSheetRow(noAlbum, row("itk_00000010", "", -1, -1)) == "Fixture Artist E", "no album: the artist alone");
    ActionRoot neither = root("itk_00000010", "", "", "");
    DryRunRow withPath = row("itk_00000010", "/lib/A", 2, -1);
    withPath.rootPath = "/income/dump/Some Folder/";
    CHECK(executeSheetRow(neither, withPath) == "Some Folder" + kArrow + "/lib/A (2 files)",
          "neither: the folder name, from the row's root_path when the menu had none");
}

static void testSheetText() {
    g_context = "sheet-text";
    ExecutePlan p;
    for (int i = 0; i < 12; i++) {
        char id[16], album[32];
        snprintf(id, sizeof id, "itk_%08x", 0x100 + i);
        snprintf(album, sizeof album, "Album %02d", i + 1);
        p.placeable.push_back(root(id, "Fixture Artist", album));
        p.rows.push_back(row(id, "/lib/T", 2, 0));
    }
    p.excluded.push_back(root("itk_00000200", "Fixture Artist", "Refused Album"));
    p.excludedWhy.push_back("Target folder already exists: target path already exists (/lib/R)");
    CHECK(executeSheetTitle(p) == "Place 12 albums in the library?", "title: N albums");
    const std::string text = executeSheetText(p);
    CHECK(text.find("Album 10") != std::string::npos && text.find("Album 11") == std::string::npos,
          "at most 10 rows");
    CHECK(text.find("\nand 2 more\n") != std::string::npos, "then and N more");
    CHECK(text.find("\n\nExcluded:\nFixture Artist" + kDash +
                    "Refused Album: Target folder already exists: target path already exists (/lib/R)") !=
              std::string::npos,
          "then the excluded roots with their error");
    CHECK(text.find("keeps running if foobar2000 quits") != std::string::npos, "and the background note");
    const std::string first = text.substr(0, text.find('\n'));
    CHECK(first == "Fixture Artist" + kDash + "Album 01" + kArrow + "/lib/T (2 files, 0 shadows skipped)",
          "the first row");

    const std::string summary = executeSheetSummary(p);
    CHECK(summary.rfind("12 placeable, 1 excluded: Fixture Artist" + kDash + "Album 01", 0) == 0,
          "summary: counts, then the rows");
    CHECK(summary.find(" | and 2 more | excluded: Fixture Artist" + kDash + "Refused Album: ") != std::string::npos,
          "summary: the cap, then the excluded");

    ExecutePlan one;
    one.placeable.push_back(root("itk_00000010", "Fixture Artist", "Approved Album"));
    one.rows.push_back(row("itk_00000010", "/lib/A", 2, 0));
    CHECK(executeSheetTitle(one) == "Place this album in the library?", "title: one album");
    CHECK(executeSheetText(one).find("Excluded") == std::string::npos, "no excluded section without excluded roots");
    CHECK(executeSheetSummary(one) == "1 placeable, 0 excluded: Fixture Artist" + kDash + "Approved Album" + kArrow +
                                          "/lib/A (2 files, 0 shadows skipped)",
          "summary of one");
    ExecutePlan nothing;
    CHECK(executeSheetSummary(nothing) == "0 placeable, 0 excluded", "summary of nothing");
}

// A real dry run: the mock's approved root passes, a proposed one is
// refused with E_BAD_STATUS in errors[] only.
static void testAgainstMock() {
    g_context = "mock";
    std::string state = mock::setupState();
    CHECK(!state.empty(), "mock state");
    std::string noBun = mock::newDir("nobun");
    CliConfig config;
    config.cliPath = mock::mockPath();
    config.bunSearchDirs = {noBun};
    config.baseEnvironment = mock::mockEnv(state);
    config.cliVersion = "0.3.0";
    CliRequest request;
    request.command = CliCommand::Execute;
    request.ids = {"itk_00000010", "itk_0000000d"};
    request.dryRun = true;
    CliRunOptions options;
    options.outputDirectory = mock::newDir("out");
    ProcessRunner runner;
    dispatch_queue_t queue = dispatch_queue_create("intake.tests.plan", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    auto result = std::make_shared<CliResult>();
    const bool started = startCliCommand(runner, config, request, options, queue, nullptr,
                                         [result, done](CliResult &&r) {
                                             *result = std::move(r);
                                             dispatch_semaphore_signal(done);
                                         },
                                         nullptr);
    CHECK(started && dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) == 0,
          "the dry run ran");
    CHECK(result->commandClass == CommandClass::ExecuteDryRun && result->envelope.outcome == CliOutcome::Partial,
          "execute --dry-run: partial (one refused)");
    if (result->envelope.outcome != CliOutcome::Partial) {
        printf("  outcome %s: %s; stdout %s\n", cliOutcomeName(result->envelope.outcome),
               result->envelope.detail.c_str(), result->process.stdoutData.c_str());
    }
    std::vector<ActionRoot> roots = {root("itk_00000010", "Fixture Artist", "Approved Album",
                                          (state + "/root/income/dump/Fixture Artist - Approved Album").c_str()),
                                     root("itk_0000000d", "Fixture Artist", "Proposed Album",
                                          (state + "/root/income/dump/Fixture Artist - Proposed Album").c_str())};
    ExecutePlan p = planExecute(roots, result->envelope);
    CHECK(placeableIds(p) == v({"itk_00000010"}), "the approved root is placeable");
    CHECK(p.rows.size() == 1 && p.rows[0].hasFiles && p.rows[0].files == 2 && p.rows[0].hasShadows &&
              p.rows[0].skippedShadows == 0,
          "with its counts");
    CHECK(p.excludedWhy == v({"Not allowed in the current state: cannot execute from status proposed"}),
          "the proposed root is excluded with the CLI's refusal");
    CHECK(!p.placeable.empty() && executeSheetRow(p.placeable[0], p.rows[0]) ==
              "Fixture Artist" + kDash + "Approved Album" + kArrow + state +
                  "/root/library/music.hq/Test Collection A/Fixture Artist/Fixture Artist - 2026 - Approved Album (2 "
                  "files, 0 shadows skipped)",
          "the sheet row for the mock's approved root");
    CHECK(mock::lastLine(mock::callsLog(state)) == "execute\titk_00000010\titk_0000000d\t--dry-run\t--json",
          "calls.log: execute <ids> --dry-run --json");
}

int main() {
    @autoreleasepool {
        mock::trackedMutex();
        mock::tracked();
        atexit([] { mock::killLeftovers(); });
        testParseRows();
        testPlan();
        testSheetRows();
        testSheetText();
        testAgainstMock();
        mock::killLeftovers();
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
