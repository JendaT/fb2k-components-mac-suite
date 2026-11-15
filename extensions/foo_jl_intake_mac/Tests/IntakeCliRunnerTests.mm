//
//  IntakeCliRunnerTests.mm
//  foo_jl_intake_mac
//
//  End-to-end CLI calls through IntakeCliRunner against
//  Tests/mock-cli/intake-mock: every mock mode mapped to its outcome and
//  error scope, the zero-id invariant (nothing reaches the mock: calls.log
//  stays as setup left it), literal argument passing, the command classes,
//  and the E_NO_CLI configurations. Each case gets a fresh mock state.
//
//  Compiled standalone under ASan+UBSan; see Scripts/run_tests.sh.
//
// TEST_DEPS: src/Core/IntakeCommandArgs.mm src/Core/IntakeEnvelope.mm src/Core/IntakeErrorMap.mm
// TEST_DEPS: src/Core/IntakeProcess.mm src/Core/IntakeLog.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeCliRunner.h"
#include "../src/Core/IntakeErrorMap.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <atomic>
#include <memory>

using intake::CliCommand;
using intake::CliOutcome;
using intake::CliRequest;
using intake::CliResult;
using intake::CommandClass;
using intake::ErrorScope;

namespace {

dispatch_queue_t g_callbacks;
std::string g_noBunDir; // an empty directory: no bun is ever found by accident

struct CliRun {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    std::atomic<int> budgetCalls{0};
    std::atomic<int> completions{0};
    bool started = false;
    std::string refusal;
    CliResult result;
};

intake::CliConfig mockConfig(const std::string &state) {
    intake::CliConfig config;
    config.cliPath = mock::mockPath();
    config.bunSearchDirs = {g_noBunDir};
    config.baseEnvironment = mock::mockEnv(state);
    return config;
}

intake::CliRunOptions testOptions(double budget = 10) {
    intake::CliRunOptions options;
    options.limits.budgetSeconds = budget;
    options.limits.killGraceSeconds = 0.5;
    options.limits.drainGraceSeconds = 0.3;
    options.limits.hardCapSeconds = 60;
    options.outputDirectory = mock::newDir("out");
    return options;
}

std::shared_ptr<CliRun> runCli(intake::ProcessRunner &runner, const intake::CliConfig &config,
                               const CliRequest &request, const intake::CliRunOptions &options) {
    auto run = std::make_shared<CliRun>();
    run->started = intake::startCliCommand(
        runner, config, request, options, g_callbacks, [run] { run->budgetCalls++; },
        [run](CliResult &&r) {
            run->result = std::move(r);
            run->completions++;
            if (run->result.process.pid > 0) {
                mock::trackGroup(run->result.process.pid, run->result.process.pid);
            }
            dispatch_semaphore_signal(run->done);
        },
        &run->refusal);
    if (run->started &&
        dispatch_semaphore_wait(run->done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) != 0) {
        printf("  (no completion within 20 s)\n");
    }
    return run;
}

CliRequest request(CliCommand command, std::vector<std::string> ids = {}) {
    CliRequest r;
    r.command = command;
    r.ids = std::move(ids);
    return r;
}

bool hasCode(const CliResult &r, const std::string &code) {
    for (const intake::CliError &e : r.envelope.errors) {
        if (e.code == code) return true;
    }
    return false;
}

std::vector<std::string> ids(const CliResult &r) {
    return intake::idsInData(r.envelope.data);
}

// Drains g_callbacks, so any completion that was queued has run.
void flushCallbacks() {
    dispatch_sync(g_callbacks, ^{});
}

// --- tests ---

void testVersionAndStatus(intake::ProcessRunner &runner) {
    g_context = "version-status";
    std::string state = mock::setupState();
    CHECK(!state.empty(), "mock state set up");
    auto run = runCli(runner, mockConfig(state), request(CliCommand::Version), testOptions());
    CHECK(run->started, "version started");
    CHECK(run->result.envelope.outcome == CliOutcome::Ok, "version: Ok");
    CHECK(run->result.commandClass == CommandClass::ReadOnly, "version: read-only class");
    NSDictionary *data = run->result.envelope.data;
    CHECK([data isKindOfClass:[NSDictionary class]] && [data[@"cli"] isEqual:@"0.2.1"] &&
              [data[@"schema"] isEqual:@1],
          "version data: cli 0.2.1, schema 1");

    run = runCli(runner, mockConfig(state), request(CliCommand::Status), testOptions());
    CHECK(run->result.envelope.outcome == CliOutcome::Ok, "status: Ok");
    CHECK_EQ(ids(run->result).size(), 15, "status: 15 roots");
    CHECK(mock::lastLine(mock::callsLog(state)) == "status\t--json", "status argv as expected");

    CliRequest filtered = request(CliCommand::Status);
    filtered.filters = {{"status", "proposed"}};
    run = runCli(runner, mockConfig(state), filtered, testOptions());
    CHECK(run->result.envelope.outcome == CliOutcome::Ok && ids(run->result).size() == 4,
          "status --filter status=proposed: the 4 proposed roots");
}

struct ModeCase {
    const char *mode;
    CliOutcome outcome;
    const char *code; // expected error code, or nullptr for none
    ErrorScope scope;
    double budget;
};

void testStatusModes(intake::ProcessRunner &runner) {
    const ModeCase cases[] = {
        {"exit2", CliOutcome::Failed, "E_INTERNAL", ErrorScope::PerCommand, 10},
        {"exit2 E_NO_RULES", CliOutcome::Failed, "E_NO_RULES", ErrorScope::ProviderInert, 10},
        {"partial", CliOutcome::Partial, "E_PARSE", ErrorScope::PerCommand, 10},
        {"garbage", CliOutcome::NoCli, "E_NO_CLI", ErrorScope::ProviderInert, 10},
        {"empty", CliOutcome::NoCli, "E_NO_CLI", ErrorScope::ProviderInert, 10},
        {"bare-array", CliOutcome::NoCli, "E_NO_CLI", ErrorScope::ProviderInert, 10},
        {"noise", CliOutcome::Ok, nullptr, ErrorScope::PerCommand, 10},
        {"hang", CliOutcome::Timeout, "E_CLI_TIMEOUT", ErrorScope::ProviderInert, 0.3},
        {"slow 2", CliOutcome::Timeout, "E_CLI_TIMEOUT", ErrorScope::ProviderInert, 0.3},
        {"big", CliOutcome::Ok, nullptr, ErrorScope::PerCommand, 10},
        {"unknown-code", CliOutcome::Failed, "E_MOCK_UNKNOWN_CODE", ErrorScope::PerCommand, 10},
        {"fds", CliOutcome::Ok, nullptr, ErrorScope::PerCommand, 10},
    };
    for (const ModeCase &c : cases) {
        g_context = std::string("status mode ") + c.mode;
        std::string state = mock::setupState();
        mock::setMode(state, "status", c.mode);
        auto run = runCli(runner, mockConfig(state), request(CliCommand::Status), testOptions(c.budget));
        mock::trackHangPids(state);
        const CliResult &r = run->result;
        CHECK(r.envelope.outcome == c.outcome, "outcome");
        if (r.envelope.outcome != c.outcome) {
            printf("  got %s (%s)\n", intake::cliOutcomeName(r.envelope.outcome), r.envelope.detail.c_str());
        }
        if (c.code) {
            CHECK(hasCode(r, c.code), "error code");
        } else {
            CHECK(r.envelope.errors.empty(), "no errors");
        }
        CHECK(intake::resultScope(CliCommand::Status, r.envelope) == c.scope, "scope");
        if (c.outcome == CliOutcome::Timeout) {
            CHECK_EQ(run->budgetCalls.load(), 1, "budget reported once");
            CHECK(r.process.elapsedSeconds < 0.3 + 0.5 + 0.3 + 2.0, "killed promptly");
        }
    }
    mock::killLeftovers();

    // A few results in detail.
    g_context = "status mode details";
    std::string state = mock::setupState();
    mock::setMode(state, "status", "partial");
    auto run = runCli(runner, mockConfig(state), request(CliCommand::Status), testOptions());
    CHECK_EQ(ids(run->result).size(), 15, "partial: the successful subset is kept");

    state = mock::setupState();
    mock::setMode(state, "status", "unknown-code");
    run = runCli(runner, mockConfig(state), request(CliCommand::Status), testOptions());
    CHECK(run->result.envelope.errors.size() == 1 &&
              intake::renderError(run->result.envelope.errors[0]) ==
                  "mock: an error code no consumer knows (" + state + "/root)",
          "unknown code rendered from msg and path");

    state = mock::setupState();
    mock::setMode(state, "status", "big");
    run = runCli(runner, mockConfig(state), request(CliCommand::Status), testOptions());
    CHECK(ids(run->result).size() > 1000, "big: every row parsed");

    state = mock::setupState();
    mock::setMode(state, "status", "fds");
    run = runCli(runner, mockConfig(state), request(CliCommand::Status), testOptions());
    NSDictionary *fds = run->result.envelope.data;
    CHECK([fds isKindOfClass:[NSDictionary class]] && [fds[@"fds"] isEqual:(@[@0, @1, @2])],
          "fds: only 0, 1, 2 in the child");
}

void testInventoryScopes(intake::ProcessRunner &runner) {
    g_context = "scopes";
    std::string state = mock::setupState();
    mock::setMode(state, "version", "exit2 E_NO_RULES");
    mock::setMode(state, "collections", "exit2 E_NO_RULES");
    auto run = runCli(runner, mockConfig(state), request(CliCommand::Version), testOptions());
    CHECK(intake::resultScope(CliCommand::Version, run->result.envelope) == ErrorScope::ProviderInert,
          "E_NO_RULES on version: provider inert");
    run = runCli(runner, mockConfig(state), request(CliCommand::Collections), testOptions());
    CHECK(run->result.envelope.outcome == CliOutcome::Failed &&
              intake::resultScope(CliCommand::Collections, run->result.envelope) == ErrorScope::PerCommand,
          "E_NO_RULES on collections: per command");

    mock::setMode(state, "propose", "exit2");
    run = runCli(runner, mockConfig(state), request(CliCommand::Propose, {"itk_0000000b"}), testOptions());
    CHECK(run->result.envelope.outcome == CliOutcome::Failed && hasCode(run->result, "E_INTERNAL") &&
              intake::resultScope(CliCommand::Propose, run->result.envelope) == ErrorScope::PerCommand,
          "E_INTERNAL from propose: an ordinary per-command failure");
}

void testMutatingCalls(intake::ProcessRunner &runner) {
    g_context = "mutating";
    std::string state = mock::setupState();
    intake::CliRunOptions options = testOptions();

    // A real partial: one root proposed, the compilation refused.
    auto run = runCli(runner, mockConfig(state),
                      request(CliCommand::Propose, {"itk_0000000b", "itk_00000015"}), options);
    const CliResult &p = run->result;
    CHECK(p.commandClass == CommandClass::Mutating, "propose: mutating class");
    CHECK(p.envelope.outcome == CliOutcome::Partial, "propose: partial");
    std::vector<std::string> got = ids(p);
    CHECK(got.size() == 1 && got[0] == "itk_0000000b", "success per root: only b is in data");
    CHECK(p.envelope.errors.size() == 1 && p.envelope.errors[0].code == "E_NO_TARGET" &&
              p.envelope.errors[0].hasPath &&
              p.envelope.errors[0].path == state + "/root/income/dump/Various Artists - Test Compilation",
          "the refusal keeps its code and path");
    CHECK(mock::listDir(options.outputDirectory).empty(), "output files removed after reading");

    // "[A & B]" reaches the CLI byte for byte.
    CliRequest assign = request(CliCommand::Assign, {"itk_0000000e"});
    assign.collection = "[A & B]";
    run = runCli(runner, mockConfig(state), assign, options);
    CHECK(run->result.envelope.outcome == CliOutcome::Ok, "assign: Ok");
    CHECK(mock::lastLine(mock::callsLog(state)) ==
              "assign\titk_0000000e\t--collection\t[A & B]\t--by\tuser\t--json",
          "assign argv reached the mock literally");
    NSArray *rows = run->result.envelope.data;
    CHECK([rows isKindOfClass:[NSArray class]] && rows.count == 1 &&
              [rows[0][@"target_collection"] isEqual:@"[A & B]"],
          "the CLI saw the collection name unchanged");

    CliRequest reject = request(CliCommand::Reject, {"itk_0000000a"});
    reject.reason = "dup of 'x' & $(y) *";
    run = runCli(runner, mockConfig(state), reject, options);
    CHECK(run->result.envelope.outcome == CliOutcome::Ok, "reject: Ok");
    CHECK(mock::lastLine(mock::callsLog(state)) ==
              "reject\titk_0000000a\t--reason\tdup of 'x' & $(y) *\t--json",
          "reject reason passed literally, no shell");

    run = runCli(runner, mockConfig(state), request(CliCommand::Execute, {"itk_00000010"}), options);
    CHECK(run->result.commandClass == CommandClass::Detached, "execute: detached class");
    got = ids(run->result);
    CHECK(run->result.envelope.outcome == CliOutcome::Ok && got.size() == 1 && got[0] == "itk_00000010",
          "execute: Ok");

    run = runCli(runner, mockConfig(state), request(CliCommand::Resume, {"itk_00000011"}), options);
    CHECK(mock::lastLine(mock::callsLog(state)) == "execute\titk_00000011\t--resume\t--json",
          "resume argv");
    CHECK(run->result.envelope.outcome == CliOutcome::Ok && ids(run->result).size() == 1, "resume: Ok");

    CliRequest gcDry = request(CliCommand::Gc, {"itk_00000012"});
    gcDry.dryRun = true;
    run = runCli(runner, mockConfig(state), gcDry, options);
    CHECK(mock::lastLine(mock::callsLog(state)) == "gc\titk_00000012\t--dry-run\t--json", "gc --dry-run argv");
    CHECK(run->result.commandClass == CommandClass::Mutating && run->result.envelope.outcome == CliOutcome::Ok,
          "gc --dry-run: mutating lane, Ok");
    run = runCli(runner, mockConfig(state), request(CliCommand::Gc, {"itk_00000012"}), options);
    CHECK(run->result.envelope.outcome == CliOutcome::Ok && ids(run->result).size() == 1, "gc one root: Ok");

    CHECK(mock::listDir(options.outputDirectory).empty(), "no output file left behind");
}

void testSlowMutatingReportsThenCompletes(intake::ProcessRunner &runner) {
    g_context = "slow-mutating";
    std::string state = mock::setupState();
    mock::setMode(state, "approve", "slow 1");
    auto run = runCli(runner, mockConfig(state), request(CliCommand::Approve, {"itk_0000000d"}),
                      testOptions(0.3));
    CHECK_EQ(run->budgetCalls.load(), 1, "E_CLI_TIMEOUT reported at the budget");
    CHECK(run->result.process.budgetExceeded && !run->result.process.killedForTimeout,
          "kept running past the budget");
    std::vector<std::string> got = ids(run->result);
    CHECK(run->result.envelope.outcome == CliOutcome::Ok && got.size() == 1 && got[0] == "itk_0000000d",
          "the real result arrived after the timeout report");
}

void testZeroIdsRefused(intake::ProcessRunner &runner) {
    g_context = "zero-ids";
    std::string state = mock::setupState();
    const std::string logAfterSetup = mock::callsLog(state);
    CHECK(logAfterSetup == "--mock-setup\tdefault\n", "calls.log holds only the setup line");

    const CliCommand mutating[] = {CliCommand::Propose, CliCommand::Assign, CliCommand::Approve,
                                   CliCommand::Reject, CliCommand::Execute, CliCommand::Resume};
    int refused = 0, total = 0, completions = 0;
    for (CliCommand cmd : mutating) {
        for (bool dry : {false, true}) {
            CliRequest r = request(cmd);
            r.dryRun = dry;
            if (cmd == CliCommand::Assign) r.collection = "Test Collection A";
            auto run = runCli(runner, mockConfig(state), r, testOptions());
            total++;
            if (!run->started && !run->refusal.empty()) refused++;
            completions += run->completions.load();
        }
    }
    flushCallbacks();
    CHECK_EQ(refused, total, "every mutating command with no ids is refused");
    CHECK_EQ(completions, 0, "no handler ran for a refused call");
    CHECK(mock::callsLog(state) == logAfterSetup, "nothing reached the mock");

    // Invalid ids could select more than meant, or turn into flags.
    const char *badIds[] = {"--approved", "--all", "--all-resolved", "itk_0000000G", "itk_0000000b ",
                            "ITK_0000000B", "", "/tmp", "income/dump"};
    int badRefused = 0;
    for (const char *bad : badIds) {
        auto run = runCli(runner, mockConfig(state), request(CliCommand::Execute, {"itk_00000010", bad}),
                          testOptions());
        if (!run->started) badRefused++;
    }
    flushCallbacks();
    CHECK_EQ(badRefused, (int)(sizeof badIds / sizeof badIds[0]), "every invalid id is refused");
    CHECK(mock::callsLog(state) == logAfterSetup, "still nothing reached the mock");
}

void testZeroIdsGcRefused(intake::ProcessRunner &runner) {
    g_context = "zero-ids-gc";
    std::string state = mock::setupState();
    const std::string logAfterSetup = mock::callsLog(state);
    auto run = runCli(runner, mockConfig(state), request(CliCommand::Gc), testOptions());
    CHECK(!run->started, "bare gc is refused");
    CHECK(run->refusal.find("no ids") != std::string::npos, "the refusal says why");
    CliRequest dry = request(CliCommand::Gc);
    dry.dryRun = true;
    auto dryRun = runCli(runner, mockConfig(state), dry, testOptions());
    CHECK(!dryRun->started, "bare gc --dry-run is refused too");
    flushCallbacks();
    CHECK(run->completions.load() == 0 && dryRun->completions.load() == 0, "no handler ran");
    CHECK(mock::callsLog(state) == logAfterSetup, "gc never reached the mock");
}

void testNoCliConfigurations(intake::ProcessRunner &runner) {
    g_context = "no-cli";
    std::string state = mock::setupState();
    const std::string logAfterSetup = mock::callsLog(state);

    intake::CliConfig empty = mockConfig(state);
    empty.cliPath.clear();
    auto run = runCli(runner, empty, request(CliCommand::Status), testOptions());
    CHECK(run->started && run->result.envelope.outcome == CliOutcome::NoCli && hasCode(run->result, "E_NO_CLI"),
          "no CLI path: E_NO_CLI through the completion");
    CHECK(run->result.process.pid == 0, "no CLI path: nothing spawned");

    intake::CliConfig missing = mockConfig(state);
    missing.cliPath = "/nonexistent/intake";
    run = runCli(runner, missing, request(CliCommand::Status), testOptions());
    CHECK(run->result.envelope.outcome == CliOutcome::NoCli, "missing binary: E_NO_CLI");
    CHECK(intake::resultScope(CliCommand::Status, run->result.envelope) == ErrorScope::ProviderInert,
          "missing binary on status: provider inert");

    intake::CliConfig ts = mockConfig(state);
    ts.cliPath = mock::newDir("cli") + "/cli.ts";
    mock::writeFile(ts.cliPath, "// not run\n");
    run = runCli(runner, ts, request(CliCommand::Status), testOptions());
    CHECK(run->result.envelope.outcome == CliOutcome::NoCli &&
              run->result.envelope.detail.find("bun") != std::string::npos,
          ".ts without bun: E_NO_CLI naming bun");

    intake::CliConfig noState = mockConfig("");
    run = runCli(runner, noState, request(CliCommand::Status), testOptions());
    CHECK(run->result.envelope.outcome == CliOutcome::NoCli &&
              run->result.envelope.detail == "exit code 64",
          "a CLI that refuses to run (exit 64): E_NO_CLI");

    intake::CliRunOptions noOut = testOptions();
    noOut.outputDirectory.clear();
    run = runCli(runner, mockConfig(state), request(CliCommand::Approve, {"itk_0000000d"}), noOut);
    CHECK(!run->started, "a mutating call without an output directory is refused");
    flushCallbacks();
    CHECK(mock::callsLog(state) == logAfterSetup, "none of these reached the mock");
}

void testTsThroughBun(intake::ProcessRunner &runner) {
    g_context = "bun";
    std::string state = mock::setupState();
    std::string dir = mock::newDir("bun");
    std::string cli = dir + "/cli.ts";
    mock::writeFile(cli, "// stands in for tools/intake/src/cli.ts\n");
    // A stand-in bun: records what it was asked to run, then runs the mock.
    mock::writeFile(dir + "/bun",
                    "#!/bin/bash\n"
                    "printf '%s\\n' \"$1\" > '" + dir + "/arg1'\n"
                    "printf '%s\\n' \"$PATH\" > '" + dir + "/path'\n"
                    "shift\n"
                    "exec '" + mock::mockPath() + "' \"$@\"\n",
                    0755);
    intake::CliConfig config = mockConfig(state);
    config.cliPath = cli;
    config.bunSearchDirs = {g_noBunDir, dir};
    auto run = runCli(runner, config, request(CliCommand::Status), testOptions());
    CHECK(run->result.envelope.outcome == CliOutcome::Ok && ids(run->result).size() == 15,
          ".ts CLI ran through bun");
    CHECK(mock::readFile(dir + "/arg1") == cli + "\n", "bun got the .ts path as its first argument");
    CHECK(mock::readFile(dir + "/path").rfind(dir + ":/opt/homebrew/bin:/usr/local/bin:", 0) == 0,
          "PATH starts with the bun directory, then the standard directories");
}

} // anonymous namespace

int main(void) {
    @autoreleasepool {
        mock::trackedMutex();
        mock::tracked();
        atexit([] { mock::killLeftovers(); });
        g_callbacks = dispatch_queue_create("intake.tests.callbacks", DISPATCH_QUEUE_SERIAL);
        g_noBunDir = mock::newDir("nobun");
        intake::ProcessRunner runner;

        testVersionAndStatus(runner);
        testStatusModes(runner);
        testInventoryScopes(runner);
        testMutatingCalls(runner);
        testSlowMutatingReportsThenCompletes(runner);
        testZeroIdsRefused(runner);
        testZeroIdsGcRefused(runner);
        testNoCliConfigurations(runner);
        testTsThroughBun(runner);

        g_context = "defaults";
        std::string out = intake::defaultCliOutputDirectory();
        const std::string suffix = "/Library/Caches/foo_jl_intake";
        CHECK(out.size() > suffix.size() && out.compare(out.size() - suffix.size(), suffix.size(), suffix) == 0,
              "production output directory: ~/Library/Caches/foo_jl_intake (computed, not created)");

        g_context = "teardown";
        CHECK_EQ(runner.runningCount(), 0, "no process left running");
        mock::killLeftovers();
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
