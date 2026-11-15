//
//  IntakeProcessTests.mm
//  foo_jl_intake_mac
//
//  IntakeProcess against Tests/mock-cli/intake-mock (every mode that
//  matters to the runner) and a few tiny shell scripts for process
//  mechanics the mock has no mode for (exit 126/127, self-kill, ignored
//  SIGTERM, an orphan holding stdout). Budgets are ~300 ms; timing asserts
//  have generous upper bounds. Every wait is bounded, and leftover
//  processes are swept (MockCliSupport.h).
//
//  Compiled standalone under ASan+UBSan; see Scripts/run_tests.sh.
//
// TEST_DEPS: src/Core/IntakeEnvelope.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeEnvelope.h"
#include "../src/Core/IntakeProcess.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <algorithm>
#include <atomic>
#include <memory>

using intake::BudgetPolicy;
using intake::CliOutcome;
using intake::OutputTarget;
using intake::ProcessEnd;
using intake::ProcessResult;
using intake::ProcessRunner;
using intake::ProcessSpec;

namespace {

using mock::Clock;

dispatch_queue_t g_callbacks;

// Shared with the handlers, so a completion arriving after a timed-out wait
// never writes into a dead stack frame.
struct Run {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    std::atomic<int> budgetCalls{0};
    double budgetAt = -1;   // seconds from start; written on g_callbacks
    bool completed = false; // written on g_callbacks before the signal
    ProcessResult result;
    Clock::time_point start;
};

// A long budget for the calls that must not time out (a loaded machine can
// take longer than 300 ms just to start bash); the timeout tests set short
// budgets themselves.
intake::ProcessLimits testLimits() {
    intake::ProcessLimits l;
    l.budgetSeconds = 10;
    l.killGraceSeconds = 0.5;
    l.hardCapSeconds = 60;
    l.drainGraceSeconds = 0.3;
    return l;
}

ProcessSpec mockSpec(const std::string &state, std::vector<std::string> args,
                     BudgetPolicy policy = BudgetPolicy::KillAtBudget,
                     OutputTarget output = OutputTarget::Pipes) {
    ProcessSpec spec;
    spec.executable = mock::mockPath();
    spec.arguments = {mock::mockPath()};
    spec.arguments.insert(spec.arguments.end(), args.begin(), args.end());
    spec.environment = mock::mockEnv(state);
    spec.policy = policy;
    spec.output = output;
    spec.limits = testLimits();
    return spec;
}

ProcessSpec scriptSpec(const std::string &script, BudgetPolicy policy = BudgetPolicy::KillAtBudget) {
    ProcessSpec spec;
    spec.executable = script;
    spec.arguments = {script};
    spec.environment = mock::mockEnv("");
    spec.policy = policy;
    spec.limits = testLimits();
    return spec;
}

std::shared_ptr<Run> startRun(ProcessRunner &runner, ProcessSpec spec) {
    auto run = std::make_shared<Run>();
    run->start = Clock::now();
    runner.start(
        std::move(spec), g_callbacks,
        [run](pid_t) {
            run->budgetCalls++;
            run->budgetAt = mock::secondsSince(run->start);
        },
        [run](ProcessResult &&r) {
            run->result = std::move(r);
            run->completed = true;
            if (run->result.pid > 0) mock::trackGroup(run->result.pid, run->result.pid);
            dispatch_semaphore_signal(run->done);
        });
    return run;
}

bool wait(const std::shared_ptr<Run> &run, double seconds = 20) {
    return dispatch_semaphore_wait(run->done, dispatch_time(DISPATCH_TIME_NOW,
                                                            (int64_t)(seconds * NSEC_PER_SEC))) == 0;
}

std::shared_ptr<Run> runToEnd(ProcessRunner &runner, ProcessSpec spec, double seconds = 20) {
    auto run = startRun(runner, std::move(spec));
    if (!wait(run, seconds)) printf("  (no completion within %.0f s)\n", seconds);
    return run;
}

std::string writeScript(const std::string &dir, const std::string &name, const std::string &body,
                        mode_t mode = 0755) {
    std::string path = dir + "/" + name;
    mock::writeFile(path, "#!/bin/bash\n" + body, mode);
    return path;
}

intake::EnvelopeResult parsed(const Run &run) {
    return intake::interpretProcessResult(run.result);
}

// --- tests ---

void testPipesBasic(ProcessRunner &runner) {
    g_context = "pipes";
    std::string state = mock::setupState();
    CHECK(!state.empty(), "mock state set up");
    auto run = runToEnd(runner, mockSpec(state, {"status", "--json"}));
    CHECK(run->completed, "completion arrived");
    CHECK(run->result.end == ProcessEnd::Exited, "exited");
    CHECK_EQ(run->result.exitCode, 0, "exit code");
    CHECK(run->result.stdoutEOF, "stdout reached EOF");
    CHECK(run->result.stderrData.empty(), "no stderr");
    CHECK_EQ(run->budgetCalls.load(), 0, "no budget report");
    intake::EnvelopeResult env = parsed(*run);
    CHECK(env.outcome == CliOutcome::Ok, "status parses as Ok");
    CHECK_EQ(intake::idsInData(env.data).size(), 15, "15 roots");
}

void testFilesOutput(ProcessRunner &runner) {
    g_context = "files";
    std::string state = mock::setupState();
    std::string out = mock::newDir("out");
    // Files output without an output directory: refused before spawning.
    auto run = runToEnd(runner, mockSpec(state, {"status", "--json"}, BudgetPolicy::ReportAtBudget,
                                         OutputTarget::Files));
    CHECK(run->result.end == ProcessEnd::SpawnFailed && run->result.spawnStage == "output directory",
          "files: no output directory, no spawn");
    CHECK(mock::callsLog(state).find("status") == std::string::npos, "files: the mock never ran");

    ProcessSpec spec = mockSpec(state, {"status", "--json"}, BudgetPolicy::ReportAtBudget,
                                OutputTarget::Files);
    spec.outputDirectory = out + "/nested/dir"; // created on demand
    run = runToEnd(runner, spec);
    CHECK(run->result.end == ProcessEnd::Exited && run->result.exitCode == 0, "files: exited 0");
    CHECK(run->result.outputError.empty(), "files: output read back");
    CHECK(parsed(*run).outcome == CliOutcome::Ok, "files: status parses as Ok");
    CHECK(mock::listDir(out + "/nested/dir").empty(), "files: output files deleted after reading");
    CHECK(run->result.stdoutPath.empty(), "files: no path reported without keepOutputFiles");

    spec.keepOutputFiles = true;
    run = runToEnd(runner, spec);
    CHECK(!run->result.stdoutPath.empty() && mock::fileExists(run->result.stdoutPath),
          "keep: stdout file kept");
    CHECK(mock::fileExists(run->result.stderrPath), "keep: stderr file kept");
    CHECK(mock::readFile(run->result.stdoutPath) == run->result.stdoutData,
          "keep: file content equals the result");
    struct stat st;
    CHECK(stat(run->result.stdoutPath.c_str(), &st) == 0 && (st.st_mode & 0777) == 0600,
          "keep: output file is private (0600)");
    unlink(run->result.stdoutPath.c_str());
    unlink(run->result.stderrPath.c_str());
}

void testSpawnFailures(ProcessRunner &runner, const std::string &scripts) {
    g_context = "spawn-failures";
    auto run = runToEnd(runner, scriptSpec("/nonexistent/intake-cli"));
    CHECK(run->result.end == ProcessEnd::SpawnFailed, "missing binary: spawn failed");
    CHECK_EQ(run->result.spawnErrno, ENOENT, "missing binary: ENOENT");
    CHECK(run->result.pid == 0, "missing binary: no pid");
    intake::EnvelopeResult env = parsed(*run);
    CHECK(env.outcome == CliOutcome::NoCli && env.errors.size() == 1 &&
              env.errors[0].code == intake::kErrorNoCli,
          "missing binary: E_NO_CLI");

    std::string noExec = writeScript(scripts, "not-executable", "echo hi\n", 0644);
    run = runToEnd(runner, scriptSpec(noExec));
    CHECK(run->result.end == ProcessEnd::SpawnFailed, "chmod -x: spawn failed");
    CHECK_EQ(run->result.spawnErrno, EACCES, "chmod -x: EACCES");
    CHECK(parsed(*run).outcome == CliOutcome::NoCli, "chmod -x: E_NO_CLI");

    ProcessSpec nul = scriptSpec("/bin/echo");
    nul.arguments.push_back(std::string("a\0b", 3));
    run = runToEnd(runner, nul);
    CHECK(run->result.end == ProcessEnd::SpawnFailed && run->result.spawnErrno == EINVAL &&
              run->result.spawnStage == "arguments",
          "an argument with a NUL byte is refused");

    ProcessSpec relative = scriptSpec("/bin/echo");
    relative.output = OutputTarget::Files;
    relative.outputDirectory = "relative/out";
    run = runToEnd(runner, relative);
    CHECK(run->result.end == ProcessEnd::SpawnFailed && run->result.spawnStage == "output directory",
          "a relative output directory is refused");

    ProcessSpec underFile = scriptSpec("/bin/echo");
    underFile.output = OutputTarget::Files;
    underFile.outputDirectory = noExec + "/out"; // a path below a regular file
    run = runToEnd(runner, underFile);
    CHECK(run->result.end == ProcessEnd::SpawnFailed && run->result.spawnStage == "output directory",
          "an uncreatable output directory fails the spawn");
}

void testExitStatuses(ProcessRunner &runner, const std::string &scripts) {
    g_context = "exit-statuses";
    auto run = runToEnd(runner, scriptSpec(writeScript(scripts, "exit127", "exit 127\n")));
    CHECK(run->result.end == ProcessEnd::Exited && run->result.exitCode == 127, "exit 127 seen");
    CHECK(parsed(*run).outcome == CliOutcome::NoCli, "exit 127: E_NO_CLI");

    run = runToEnd(runner, scriptSpec(writeScript(scripts, "exit126", "exit 126\n")));
    CHECK(run->result.exitCode == 126 && parsed(*run).outcome == CliOutcome::NoCli, "exit 126: E_NO_CLI");

    run = runToEnd(runner, scriptSpec(writeScript(scripts, "selfkill", "kill -KILL $$\n")));
    CHECK(run->result.end == ProcessEnd::Signaled && run->result.termSignal == SIGKILL,
          "a self-inflicted SIGKILL is reported");
    CHECK(!run->result.killedForTimeout, "not counted as our timeout kill");
    CHECK(parsed(*run).outcome == CliOutcome::NoCli, "death by a foreign signal: E_NO_CLI");

    // The mock refuses to run without INTAKE_MOCK_STATE: exit 64.
    run = runToEnd(runner, mockSpec("", {"status", "--json"}));
    CHECK(run->result.end == ProcessEnd::Exited && run->result.exitCode == 64, "mock refusal: exit 64");
    CHECK(!run->result.stderrData.empty(), "mock refusal: the reason is on stderr");
    CHECK(parsed(*run).outcome == CliOutcome::NoCli, "mock refusal: E_NO_CLI");
}

void testHangKilledAtBudget(ProcessRunner &runner) {
    g_context = "hang";
    std::string state = mock::setupState();
    mock::setMode(state, "status", "hang");
    ProcessSpec spec = mockSpec(state, {"status", "--json"});
    spec.limits.budgetSeconds = 0.5; // the mock writes hang.pid well before this
    spec.limits.killGraceSeconds = 1.0;
    auto run = startRun(runner, spec);
    bool hanging = mock::waitUntil([&] { return mock::fileExists(state + "/hang.pid"); }, 5.0);
    CHECK(hanging && !run->completed, "the mock is hanging with its sleeping child");
    mock::trackHangPids(state);
    CHECK(wait(run), "completion arrived");
    const ProcessResult &r = run->result;

    CHECK_EQ(run->budgetCalls.load(), 1, "the budget is reported once");
    CHECK(r.budgetExceeded && r.killedForTimeout, "killed for its budget");
    CHECK(r.end == ProcessEnd::Signaled, "ended by a signal");
    // SIGTERM worked: the child's signal mask was clean even though it was
    // spawned from a GCD thread, so no SIGKILL was needed.
    CHECK_EQ(r.termSignal, SIGTERM, "SIGTERM ended it");
    CHECK(r.elapsedSeconds >= 0.45, "not before the budget");
    CHECK(r.elapsedSeconds < 0.5 + 1.0 + 0.3 + 1.5, "within budget + grace (+ slack)");
    intake::EnvelopeResult env = parsed(*run);
    CHECK(env.outcome == CliOutcome::Timeout && env.errors.size() == 1 &&
              env.errors[0].code == intake::kErrorCliTimeout,
          "E_CLI_TIMEOUT");

    CHECK(r.pid > 0 && mock::notOurChild(r.pid), "no zombie: the leader was reaped");
    CHECK(mock::waitUntil([&] { return mock::groupGone(r.pid); }, 3.0), "the process group is gone");
    int shell = 0, child = 0;
    sscanf(mock::readFile(state + "/hang.pid").c_str(), "%d %d", &shell, &child);
    CHECK(shell == r.pid, "hang.pid names the leader");
    CHECK(child > 0 && mock::waitUntil([&] { return mock::pidGone(child); }, 3.0),
          "the sleeping grandchild holding stdout is dead");
    mock::killLeftovers();
}

void testSigtermIgnoredEscalates(ProcessRunner &runner, const std::string &scripts) {
    g_context = "sigkill-escalation";
    // Ignored signals survive fork and exec, so the sleep ignores TERM too.
    std::string script = writeScript(scripts, "ignore-term", "trap '' TERM\nsleep 30 &\nwait\n");
    ProcessSpec spec = scriptSpec(script);
    spec.limits.budgetSeconds = 1.0; // bash must have run the trap before SIGTERM
    spec.limits.killGraceSeconds = 0.5;
    auto run = runToEnd(runner, spec);
    const ProcessResult &r = run->result;
    CHECK(r.end == ProcessEnd::Signaled && r.termSignal == SIGKILL, "SIGKILL after the grace");
    CHECK(r.killedForTimeout, "killed for its budget");
    CHECK(r.elapsedSeconds >= 1.0 + 0.5 - 0.05, "SIGKILL waited for the grace");
    CHECK(r.elapsedSeconds < 1.0 + 0.5 + 0.3 + 1.5, "and not much longer");
    CHECK(mock::waitUntil([&] { return mock::groupGone(r.pid); }, 3.0), "the group is gone");
    CHECK(mock::notOurChild(r.pid), "no zombie");
    mock::killLeftovers();
}

void testOrphanHoldingStdout(ProcessRunner &runner, const std::string &scripts) {
    g_context = "orphan";
    std::string script = writeScript(scripts, "orphan",
                                     "sleep 30 &\n"
                                     "echo '{\"ok\":true,\"data\":[],\"errors\":[]}'\n"
                                     "exit 0\n");
    ProcessSpec spec = scriptSpec(script);
    auto run = runToEnd(runner, spec);
    const ProcessResult &r = run->result;
    CHECK(r.end == ProcessEnd::Exited && r.exitCode == 0, "the leader exited 0");
    CHECK(!r.stdoutEOF, "stdout never reached EOF (the orphan holds it)");
    CHECK(r.elapsedSeconds < 0.3 + 1.5, "completion at most the drain grace after exit");
    CHECK(!r.killedForTimeout && run->budgetCalls.load() == 0, "no timeout");
    CHECK(parsed(*run).outcome == CliOutcome::Ok, "what was written before exit still parses");
    CHECK(mock::waitUntil([&] { return mock::groupGone(r.pid); }, 3.0),
          "read-only call: the orphan is killed with its group");
    mock::killLeftovers();
}

void testBig(ProcessRunner &runner) {
    g_context = "big";
    std::string state = mock::setupState();
    mock::setMode(state, "status", "big");
    auto run = runToEnd(runner, mockSpec(state, {"status", "--json"}));
    const ProcessResult &r = run->result;
    CHECK(r.end == ProcessEnd::Exited && r.exitCode == 0, "exited 0 (no pipe deadlock)");
    CHECK(r.stdoutData.size() >= (size_t)1 << 20, "about 1 MB read");
    CHECK(!r.stdoutTruncated, "under the 32 MB cap");
    intake::EnvelopeResult env = parsed(*run);
    CHECK(env.outcome == CliOutcome::Ok && intake::idsInData(env.data).size() > 1000,
          "the big status parses");
    CHECK(r.elapsedSeconds < 15, "finished in reasonable time");

    ProcessSpec capped = mockSpec(state, {"status", "--json"});
    capped.limits.stdoutCap = 100000;
    run = runToEnd(runner, capped);
    CHECK(run->result.end == ProcessEnd::Exited && run->result.exitCode == 0,
          "capped: the child still ran to the end (excess drained)");
    CHECK(run->result.stdoutTruncated, "capped: truncation flagged");
    CHECK_EQ(run->result.stdoutData.size(), 100000, "capped: exactly the cap kept");
    CHECK(parsed(*run).outcome == CliOutcome::NoCli, "capped: a truncated envelope is E_NO_CLI");
}

void testNoise(ProcessRunner &runner) {
    g_context = "noise";
    std::string state = mock::setupState();
    mock::setMode(state, "status", "noise");
    auto run = runToEnd(runner, mockSpec(state, {"status", "--json"}));
    const ProcessResult &r = run->result;
    CHECK(r.end == ProcessEnd::Exited && r.exitCode == 0, "exited 0");
    CHECK(r.stderrTruncated, "140 KB of stderr is over the 64 KB cap");
    CHECK_EQ(r.stderrData.size(), 64 * 1024, "stderr kept up to the cap");
    CHECK(parsed(*run).outcome == CliOutcome::Ok, "envelope wrapped in whitespace still parses");

    ProcessSpec files = mockSpec(state, {"status", "--json"}, BudgetPolicy::ReportAtBudget,
                                 OutputTarget::Files);
    files.outputDirectory = mock::newDir("out");
    run = runToEnd(runner, files);
    CHECK(run->result.stderrTruncated && run->result.stderrData.size() == 64 * 1024,
          "files: stderr capped on read-back");
    CHECK(parsed(*run).outcome == CliOutcome::Ok, "files: still parses");
}

void testSlowMutatingCompletes(ProcessRunner &runner) {
    g_context = "slow-mutating";
    std::string state = mock::setupState();
    mock::setMode(state, "propose", "slow 1");
    mock::writeFile(state + "/propose.next", "b-proposed\n");
    ProcessSpec spec = mockSpec(state, {"propose", "itk_0000000b", "--json"},
                                BudgetPolicy::ReportAtBudget, OutputTarget::Files);
    spec.outputDirectory = mock::newDir("out");
    spec.limits.budgetSeconds = 0.3;
    auto run = runToEnd(runner, spec);
    const ProcessResult &r = run->result;
    CHECK_EQ(run->budgetCalls.load(), 1, "the timeout is reported");
    CHECK(run->budgetAt >= 0.25 && run->budgetAt + 0.3 < r.elapsedSeconds,
          "reported at the budget, well before the exit");
    CHECK(r.end == ProcessEnd::Exited && r.exitCode == 0, "the command still completed");
    CHECK(r.budgetExceeded && !r.killedForTimeout, "ran past the budget, never signalled");
    CHECK(r.elapsedSeconds >= 0.95, "it ran its full second");
    intake::EnvelopeResult env = parsed(*run);
    CHECK(env.outcome == CliOutcome::Ok, "the real result is delivered");
    std::vector<std::string> ids = intake::idsInData(env.data);
    CHECK(ids.size() == 1 && ids[0] == "itk_0000000b", "the proposed root is in data");
    CHECK(!mock::fileExists(state + "/propose.next"), "its state change was applied");
}

void testHardCap(ProcessRunner &runner) {
    g_context = "hard-cap";
    std::string state = mock::setupState();
    mock::setMode(state, "propose", "hang");
    ProcessSpec spec = mockSpec(state, {"propose", "itk_0000000b", "--json"},
                                BudgetPolicy::ReportAtBudget, OutputTarget::Files);
    spec.outputDirectory = mock::newDir("out");
    spec.limits.budgetSeconds = 0.2;
    spec.limits.hardCapSeconds = 0.6;
    auto run = runToEnd(runner, spec);
    mock::trackHangPids(state);
    const ProcessResult &r = run->result;
    CHECK_EQ(run->budgetCalls.load(), 1, "the budget is reported first");
    CHECK(r.hardCapHit && r.killedForTimeout, "terminated at the hard cap");
    CHECK(r.end == ProcessEnd::Signaled && r.termSignal == SIGTERM, "by SIGTERM");
    CHECK(r.elapsedSeconds >= 0.55 && r.elapsedSeconds < 3.0, "at the hard cap, not the budget");
    CHECK(parsed(*run).outcome == CliOutcome::Timeout, "E_CLI_TIMEOUT");
    CHECK(mock::waitUntil([&] { return mock::groupGone(r.pid); }, 3.0), "the group is gone");
    mock::killLeftovers();
}

void testUnbounded(ProcessRunner &runner) {
    g_context = "unbounded";
    std::string state = mock::setupState();
    mock::setMode(state, "execute", "slow 0.6");
    ProcessSpec spec = mockSpec(state, {"execute", "itk_00000010", "--json"}, BudgetPolicy::Unbounded,
                                OutputTarget::Files);
    spec.outputDirectory = mock::newDir("out");
    spec.limits.budgetSeconds = 0.2;
    auto run = runToEnd(runner, spec);
    CHECK_EQ(run->budgetCalls.load(), 0, "no budget at all");
    CHECK(!run->result.budgetExceeded && !run->result.killedForTimeout, "never signalled");
    CHECK(run->result.end == ProcessEnd::Exited && run->result.exitCode == 0, "ran to the end");
    intake::EnvelopeResult env = parsed(*run);
    std::vector<std::string> ids = intake::idsInData(env.data);
    CHECK(env.outcome == CliOutcome::Ok && ids.size() == 1 && ids[0] == "itk_00000010",
          "execute result delivered");
}

void testCancelReadLane(ProcessRunner &runner) {
    g_context = "cancel";
    std::string state = mock::setupState();
    mock::setMode(state, "status", "hang");
    mock::setMode(state, "execute", "slow 0.8");

    ProcessSpec read = mockSpec(state, {"status", "--json"});
    read.limits.budgetSeconds = 30;
    ProcessSpec exec = mockSpec(state, {"execute", "itk_00000010", "--json"}, BudgetPolicy::Unbounded,
                                OutputTarget::Files);
    exec.outputDirectory = mock::newDir("out");
    auto readRun = startRun(runner, read);
    auto execRun = startRun(runner, exec);

    bool started = mock::waitUntil(
        [&] {
            return mock::fileExists(state + "/hang.pid") &&
                   mock::callsLog(state).find("execute\titk_00000010") != std::string::npos;
        },
        5.0);
    CHECK(started, "both processes are running");
    mock::trackHangPids(state);
    CHECK_EQ(runner.runningCount(), 2, "two processes tracked");
    CHECK_EQ(runner.cancelReadLane(), 1, "only the read-lane process is signalled");

    CHECK(wait(readRun, 5), "the read call completes promptly");
    CHECK(readRun->result.cancelled, "marked cancelled");
    CHECK(readRun->result.end == ProcessEnd::Signaled && readRun->result.termSignal == SIGKILL,
          "killed with SIGKILL");
    CHECK(readRun->result.elapsedSeconds < 3, "well before its 30 s budget");
    intake::EnvelopeResult readEnv = parsed(*readRun);
    CHECK(readEnv.outcome == CliOutcome::Cancelled && readEnv.errors.empty(),
          "cancelled is its own outcome, without an error");
    CHECK(mock::waitUntil([&] { return mock::groupGone(readRun->result.pid); }, 3.0),
          "the read group is gone");

    CHECK(wait(execRun, 10), "execute completes");
    CHECK(!execRun->result.cancelled && execRun->result.end == ProcessEnd::Exited &&
              execRun->result.exitCode == 0,
          "execute was left running and finished normally");
    CHECK(parsed(*execRun).outcome == CliOutcome::Ok, "execute result delivered");
    CHECK_EQ(runner.runningCount(), 0, "nothing left running");
    mock::killLeftovers();
}

std::mutex g_signalsMutex;
std::vector<std::pair<pid_t, int>> g_signals;

int recordOnlySender(pid_t pgid, int signal) {
    std::lock_guard<std::mutex> lock(g_signalsMutex);
    g_signals.push_back({pgid, signal});
    return 0; // pretend it was sent; the process never sees it
}

void testAbandonUnkillable() {
    g_context = "abandon";
    ProcessRunner deaf(recordOnlySender);
    std::string state = mock::setupState();
    mock::setMode(state, "status", "hang");
    ProcessSpec spec = mockSpec(state, {"status", "--json"});
    // Short enough to exit on its own soon after the abandon.
    std::replace(spec.environment.begin(), spec.environment.end(),
                 std::string("INTAKE_MOCK_HANG_SECONDS=30"), std::string("INTAKE_MOCK_HANG_SECONDS=1.5"));
    spec.limits.budgetSeconds = 0.15;
    spec.limits.killGraceSeconds = 0.15;
    auto run = runToEnd(deaf, spec);
    mock::trackHangPids(state);
    const ProcessResult &r = run->result;
    CHECK(r.end == ProcessEnd::Abandoned, "reported as abandoned");
    CHECK(r.killedForTimeout, "after the timeout kill");
    CHECK(r.elapsedSeconds >= 0.4 && r.elapsedSeconds < 1.3, "at budget + 2 x grace");
    CHECK(parsed(*run).outcome == CliOutcome::Timeout, "E_CLI_TIMEOUT");
    {
        std::lock_guard<std::mutex> lock(g_signalsMutex);
        bool term = false, kill = false;
        for (auto &s : g_signals) {
            if (s.first == r.pid && s.second == SIGTERM) term = true;
            if (s.first == r.pid && s.second == SIGKILL && term) kill = true;
        }
        CHECK(term && kill, "SIGTERM then SIGKILL were sent to the group");
    }
    CHECK_EQ(deaf.runningCount(), 1, "still watched after the completion");
    CHECK(mock::waitUntil([&] { return deaf.runningCount() == 0; }, 10.0),
          "reaped once it exits on its own");
    CHECK(mock::notOurChild(r.pid), "no zombie after the late exit");
    mock::killLeftovers();
}

void testFdsMode(ProcessRunner &runner) {
    g_context = "fds";
    // Descriptors this process leaves inheritable on purpose.
    int extra[3];
    for (int &fd : extra) fd = ::open("/dev/null", O_RDONLY);
    CHECK(extra[0] > 2 && extra[1] > 2 && extra[2] > 2, "extra inheritable descriptors open");

    std::string state = mock::setupState();
    mock::setMode(state, "status", "fds");
    for (OutputTarget target : {OutputTarget::Pipes, OutputTarget::Files}) {
        ProcessSpec spec = mockSpec(state, {"status", "--json"},
                                    target == OutputTarget::Files ? BudgetPolicy::ReportAtBudget
                                                                  : BudgetPolicy::KillAtBudget,
                                    target);
        if (target == OutputTarget::Files) spec.outputDirectory = mock::newDir("out");
        auto run = runToEnd(runner, spec);
        intake::EnvelopeResult env = parsed(*run);
        NSArray *fds = [env.data isKindOfClass:[NSDictionary class]] ? env.data[@"fds"] : nil;
        bool only012 = [fds isEqual:(@[@0, @1, @2])];
        CHECK(env.outcome == CliOutcome::Ok && only012,
              target == OutputTarget::Pipes ? "pipes: the child has only 0, 1, 2 open"
                                            : "files: the child has only 0, 1, 2 open");
        if (!only012) printf("  child fds: %s\n", fds.description.UTF8String);
    }
    for (int fd : extra) ::close(fd);
}

void testConcurrent(ProcessRunner &runner) {
    g_context = "concurrent";
    std::string state = mock::setupState();
    std::vector<std::shared_ptr<Run>> runs;
    for (int i = 0; i < 6; i++) runs.push_back(startRun(runner, mockSpec(state, {"status", "--json"})));
    int ok = 0;
    for (auto &run : runs) {
        if (wait(run) && parsed(*run).outcome == CliOutcome::Ok) ok++;
    }
    CHECK_EQ(ok, 6, "six concurrent calls all complete with Ok");
}

} // anonymous namespace

int main(void) {
    @autoreleasepool {
        // Construct the sweep's statics before registering it, so they
        // outlive the atexit handler.
        mock::trackedMutex();
        mock::tracked();
        atexit([] { mock::killLeftovers(); });
        g_callbacks = dispatch_queue_create("intake.tests.callbacks", DISPATCH_QUEUE_SERIAL);
        ProcessRunner runner;
        std::string scripts = mock::newDir("scripts");

        // Warm-up: GCD's kqueue, Foundation and the helpers open what they
        // keep open before the descriptor baseline is taken.
        {
            std::string state = mock::setupState();
            runToEnd(runner, mockSpec(state, {"version", "--json"}));
            ProcessSpec files = mockSpec(state, {"version", "--json"}, BudgetPolicy::ReportAtBudget,
                                         OutputTarget::Files);
            files.outputDirectory = mock::newDir("out");
            runToEnd(runner, files);
            mock::listDir(files.outputDirectory);
        }
        int fdsBefore = mock::countOpenFds();

        testPipesBasic(runner);
        testFilesOutput(runner);
        testSpawnFailures(runner, scripts);
        testExitStatuses(runner, scripts);
        testHangKilledAtBudget(runner);
        testSigtermIgnoredEscalates(runner, scripts);
        testOrphanHoldingStdout(runner, scripts);
        testBig(runner);
        testNoise(runner);
        testSlowMutatingCompletes(runner);
        testHardCap(runner);
        testUnbounded(runner);
        testCancelReadLane(runner);
        testAbandonUnkillable();
        testFdsMode(runner);
        testConcurrent(runner);

        g_context = "teardown";
        CHECK_EQ(runner.runningCount(), 0, "no process left running");
        int fdsAfter = mock::countOpenFds();
        CHECK(fdsBefore > 0, "descriptor count available");
        CHECK_EQ(fdsAfter, fdsBefore, "open descriptors equal before and after");
        int status = 0;
        CHECK(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD, "no child left, zombie or alive");

        mock::killLeftovers();
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
