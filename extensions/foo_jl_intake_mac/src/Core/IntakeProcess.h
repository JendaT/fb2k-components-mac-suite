//
//  IntakeProcess.h
//  foo_jl_intake
//
//  Runs one child process at a time per call, with no way to hang, deadlock,
//  leak descriptors or leave zombies (PLAN.md B1, risks 1 and 2). Generic:
//  knows nothing about the intake CLI; IntakeCliRunner composes it with
//  IntakeCommandArgs and IntakeEnvelope.
//
//  How a process is started:
//   - posix_spawn, never a shell and never NSTask (no process-group kill).
//   - POSIX_SPAWN_SETPGROUP: the child leads its own process group, so the
//     whole tree (bun, its helpers, a sleeping grandchild) is signalled with
//     one kill(-pgid).
//   - POSIX_SPAWN_CLOEXEC_DEFAULT plus explicit file actions for 0 to 2: the
//     child inherits nothing else, so a child that outlives foobar2000 never
//     holds its sockets or database files. stdin is /dev/null.
//   - The signal mask is emptied and every signal reset to its default:
//     a child spawned from a GCD thread would otherwise start with that
//     thread's blocked signals, SIGTERM included, and an inherited SIG_IGN
//     for SIGPIPE would survive exec.
//
//  Output targets:
//   - Pipes (read-lane calls): both pipes are drained by GCD read sources on
//     the runner's queue, concurrently, so a full pipe never blocks the
//     child. Caps: stdout 32 MB, stderr 64 KB by default; bytes past a cap
//     are read and dropped, and the result says so.
//   - Files (mutation-lane and execute calls): stdout and stderr go to two
//     new files in the caller's output directory (production uses
//     ~/Library/Caches/foo_jl_intake/), read with the same caps after exit
//     and then deleted. A command that outlives foobar2000 keeps writing to
//     its files and never hits SIGPIPE halfway through a non-atomic sidecar
//     write (PLAN.md 3.4). The files are named
//     intake-<pid>-<seq>-<ms>.out/.err, unique within the process. The
//     first Files call of a runner into a directory deletes the output files
//     there whose creating process no longer exists (a call that outlived
//     an earlier foobar2000 is never reaped, so nothing else would).
//   - Caller-named files (B8, detached execute runs): stdoutFileName and
//     stderrFileName replace the generated names, and stderrToDevNull sends
//     stderr to /dev/null with no file at all. A caller-named file is
//     created new (O_EXCL), read back at exit like any output, and never
//     unlinked or swept by the runner: the caller owns it. The sweep above
//     only matches the generated intake-<pid>-... names, so it can never
//     delete the output of a detached run that outlives its foobar2000 (a
//     detached call with generated names would lose them to the next
//     session's sweep while its child still writes: name them).
//
//  Spawn report (B8): start() can take a spawn handler, which runs on the
//  caller's queue as soon as the child exists, before its budget report
//  and its completion (on a serial callback queue), with the pid, the
//  child's start time (proc_pidinfo, read before the child can be reaped,
//  so the pid cannot have been reused) and the output paths. A spawn that
//  fails never calls it.
//
//  Completion: the process has exited and both pipes reached EOF, or at most
//  `drainGraceSeconds` after exit when an orphaned grandchild still holds a
//  pipe. The exit is seen by a DISPATCH_SOURCE_TYPE_PROC source and reaped
//  with waitpid, so no zombie remains. The completion handler runs exactly
//  once, on the caller's queue.
//
//  Budgets (PLAN.md 3.4):
//   - KillAtBudget (read-only calls): at the budget the budget handler runs,
//     the group gets SIGTERM, and SIGKILL `killGraceSeconds` later. The
//     result has killedForTimeout set. On completion any member of the group
//     still alive is SIGKILLed while the leader is unreaped, so its group id
//     cannot have been reused.
//   - ReportAtBudget (mutating calls): at the budget the budget handler runs
//     and the process keeps running; the completion delivers its real
//     result. At `hardCapSeconds` from the start it is terminated like a
//     read-only call (SIGTERM, then SIGKILL, and on completion the rest of
//     the group is SIGKILLed).
//   - ReportOnly (execute and resume dry runs): at the budget the budget
//     handler runs and the process keeps running, like ReportAtBudget, but
//     there is no hard cap: never signalled by the runner, not even by
//     cancelReadLane(). IntakeCliRunner turns that budget into a lane
//     release, not an E_CLI_TIMEOUT report (doc 03 excepts execute).
//   - Unbounded (execute, resume): no budget, never signalled by the runner,
//     not even by cancelReadLane().
//  A budget or hard-cap timer that fires while the leader's exit is still
//  queued sees the zombie (waitid WNOWAIT) and treats the process as exited,
//  so a call that ended right at its budget keeps its real result.
//  If a signalled process is still alive `killGraceSeconds` after its SIGKILL
//  (uninterruptible sleep on a dead network share), the completion is
//  delivered anyway with end == Abandoned; the runner keeps watching the pid
//  and reaps it whenever it exits.
//
//  Thread-safety: every method may be called from any thread. All process
//  state lives on one private serial queue. Do not call the synchronous
//  methods (cancelReadLane, closeReadLane, runningCount) from inside a
//  budget or completion handler that runs on a queue those methods could be
//  waiting behind; the runner's own queue is private, so ordinary caller
//  queues are fine.
//
//  Lifetime: the runner's state stays alive while any of its processes is
//  running, even if the ProcessRunner object is destroyed first; destroying
//  it never signals anything, and such a process is still reaped (and its
//  completion delivered) when it exits.
//

#pragma once

#include <dispatch/dispatch.h>
#include <sys/types.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace intake {

enum class OutputTarget {
    Pipes,
    Files,
};

enum class BudgetPolicy {
    KillAtBudget,   // read-only: report, SIGTERM the group, SIGKILL after the grace
    ReportAtBudget, // mutating: report, keep running; terminate at the hard cap
    ReportOnly,     // execute dry runs: budget handler, keep running; never signalled
    Unbounded,      // execute and resume: no report, never signalled by the runner
};

struct ProcessLimits {
    double budgetSeconds = 10.0;          // doc 03: the component uses 10 s
    double killGraceSeconds = 2.0;        // SIGTERM -> SIGKILL, and SIGKILL -> Abandoned
    double hardCapSeconds = 15.0 * 60.0;  // ReportAtBudget only, measured from the start
    double drainGraceSeconds = 1.0;       // after exit, the longest wait for pipe EOF
    size_t stdoutCap = size_t(32) << 20;  // 32 MB
    size_t stderrCap = size_t(64) << 10;  // 64 KB
};

struct ProcessSpec {
    std::string executable;                // run directly: no PATH search, no shell
    std::vector<std::string> arguments;    // the full argv, argv[0] included
    std::vector<std::string> environment;  // the full environment, "NAME=value" each
    OutputTarget output = OutputTarget::Pipes;
    std::string outputDirectory;           // Files only: absolute, created (0700) when missing
    bool keepOutputFiles = false;          // Files only: leave the files (diagnostics, tests)
    // Files only: a plain file name in outputDirectory (no '/', not "." or
    // "..") for stdout instead of the generated name; created new, never
    // unlinked or swept by the runner (see the top of this file).
    std::string stdoutFileName;
    std::string stderrFileName;            // the same for stderr; ignored with stderrToDevNull
    bool stderrToDevNull = false;          // Files only: stderr to /dev/null, no stderr file
    BudgetPolicy policy = BudgetPolicy::KillAtBudget;
    ProcessLimits limits;
};

// When a process started (proc_pidinfo PROC_PIDTBSDINFO pbi_start_tvsec and
// pbi_start_tvusec). With the pid it names one process for good: a reused
// pid has another start time.
struct ProcessStartTime {
    uint64_t seconds = 0;
    uint32_t micros = 0;
    bool operator==(const ProcessStartTime &other) const {
        return seconds == other.seconds && micros == other.micros;
    }
    bool operator!=(const ProcessStartTime &other) const { return !(*this == other); }
};

// The start time of `pid`. False for a pid that does not exist, a zombie
// (exited and not yet reaped: the kernel no longer reports it), or a process
// this user may not inspect (EPERM: another user's).
bool readProcessStartTime(pid_t pid, ProcessStartTime &out);

// What start() reports once the child exists (see the top of this file).
struct ProcessSpawnInfo {
    uint64_t token = 0;
    pid_t pid = 0;                // also the process group id
    bool startTimeKnown = false;  // false when the child had already exited
    ProcessStartTime startTime;
    std::string stdoutPath;       // Files: where stdout goes
    std::string stderrPath;       // Files: where stderr goes; empty for /dev/null
};

enum class ProcessEnd {
    Exited,      // exitCode is valid
    Signaled,    // termSignal is valid (our own kill included)
    SpawnFailed, // nothing ran; spawnErrno and spawnStage say why
    Abandoned,   // signalled, still alive after SIGKILL + grace; reaped later
    WaitFailed,  // waitpid could not return the status (another party reaped it)
};

struct ProcessResult {
    ProcessEnd end = ProcessEnd::SpawnFailed;
    int exitCode = -1;
    int termSignal = 0;
    int spawnErrno = 0;
    std::string spawnStage;       // SpawnFailed: "output directory", "pipe", "spawn", ...
    pid_t pid = 0;                // also the process group id; 0 when nothing ran

    bool budgetExceeded = false;  // still running when the budget elapsed
    bool killedForTimeout = false;// signalled by the runner for the budget or the hard cap
    bool hardCapHit = false;      // ReportAtBudget reached hardCapSeconds
    bool cancelled = false;       // signalled by cancelReadLane()

    std::string stdoutData;
    std::string stderrData;
    bool stdoutTruncated = false; // more than stdoutCap bytes were written
    bool stderrTruncated = false;
    bool stdoutEOF = false;       // Pipes: false when the drain grace ended the wait
    std::string outputError;      // Files: why the output could not be read back

    std::string stdoutPath;       // Files with keepOutputFiles, or caller-named: where the output is
    std::string stderrPath;       // the same; empty for /dev/null
    double elapsedSeconds = 0;
};

// Runs once on the caller's queue when the child has been spawned, before
// its budget report and completion (on a serial callback queue).
using ProcessSpawnHandler = std::function<void(const ProcessSpawnInfo &info)>;
// Runs on the caller's queue when the budget elapses (not for Unbounded).
// On a serial callback queue it always runs before the completion.
using ProcessBudgetHandler = std::function<void(pid_t pid)>;
// Runs exactly once on the caller's queue.
using ProcessCompletion = std::function<void(ProcessResult &&result)>;
// Sends `signal` to process group `pgid`; returns like kill(2). Tests
// replace it to simulate a process that ignores every signal.
using ProcessSignalSender = int (*)(pid_t pgid, int signal);

class ProcessRunner {
public:
    // `signalSender` nullptr means kill(-pgid, signal).
    explicit ProcessRunner(ProcessSignalSender signalSender = nullptr);
    ~ProcessRunner();
    ProcessRunner(const ProcessRunner &) = delete;
    ProcessRunner &operator=(const ProcessRunner &) = delete;

    // Starts `spec` asynchronously and returns a token (never 0) for logs.
    // Spawn failures arrive through `onComplete` like any other result.
    // `callbackQueue` nil means the main queue. `onBudget` may be empty.
    uint64_t start(ProcessSpec spec, dispatch_queue_t callbackQueue,
                   ProcessBudgetHandler onBudget, ProcessCompletion onComplete);
    // The same, with a spawn report (`onSpawn` may be empty).
    uint64_t start(ProcessSpec spec, dispatch_queue_t callbackQueue, ProcessSpawnHandler onSpawn,
                   ProcessBudgetHandler onBudget, ProcessCompletion onComplete);

    // Synchronously sends SIGKILL to the group of every KillAtBudget process
    // that has not exited, and marks it cancelled; its completion follows as
    // usual. ReportAtBudget, ReportOnly and Unbounded processes are left running
    // (on_quit, PLAN.md 3.2). Returns how many groups were signalled.
    size_t cancelReadLane();

    // cancelReadLane(), and the read lane stays closed: a KillAtBudget
    // process whose spawn runs after this call (a start() racing it
    // included) is never spawned; it completes with cancelled set and
    // end == SpawnFailed (stage "read lane closed", ECANCELED). Other
    // policies still start. For on_quit, so nothing read-only outlives the
    // sweep. Returns like cancelReadLane().
    size_t closeReadLane();

    // Synchronously: processes started and not yet reaped, abandoned ones
    // included. For diagnostics and tests.
    size_t runningCount() const;

    struct Impl;

private:
    std::shared_ptr<Impl> impl_;
};

} // namespace intake
