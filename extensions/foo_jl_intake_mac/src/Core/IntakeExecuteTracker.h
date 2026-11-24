//
//  IntakeExecuteTracker.h
//  foo_jl_intake
//
//  Detached execute and resume runs (PLAN.md B8, 3.7; doc 04 v1.2 "Context
//  actions" Execute and Resume bullets, "CLI invocation"). SDK-free:
//  Integration (IntakeActions) spawns the runs, keeps the tracker on the
//  main thread and does the file work on its mutation queue.
//
//  Files, all in the output directory (production:
//  ~/Library/Caches/foo_jl_intake/), sharing one stem
//  "execute-<token>" (token: 1 to 64 of [A-Za-z0-9-]; newRunStem makes
//  "execute-YYYYMMDD-HHMMSS-mmm" in local time, uniqueRunStem adds "-2"...
//  when a file of that stem exists):
//   - <stem>.json: the run's stdout, written by the CLI (the runner's
//     caller-named output: never unlinked or swept by it). stderr goes to
//     /dev/null.
//   - <stem>.run: the run file, one JSON object written atomically (to
//     <stem>.tmp, fsync, rename):
//       {"format":1, "command":"execute"|"resume", "pid":<int>,
//        "start_sec":<int>, "start_usec":<int>, "ids":["itk_..."],
//        "root_paths":["..."], "output":"<stem>.json",
//        "swap_after":true|false, "delete_after":true|false}
//     `root_paths` is optional (aligned with `ids`; used to place errors on
//     their roots when the run is finished by a later session).
//     `swap_after` and `delete_after` are optional too: the Execute sheet's
//     follow-ups (RunFollowUps, IntakeExecuteFollowUp), JSON booleans,
//     written together when the run starts. Both present as booleans: the
//     choice is recorded (delete_after counts only with swap_after true);
//     either missing or of another type: no follow-ups (a file of an older
//     build, a resume), and the file still parses. Unknown keys are
//     ignored. Everything else is required: format 1, a pid of 2
//     or more, start_sec 1 or more, start_usec 0 to 999999, at least one
//     sidecar id (repeats dropped), and an output name of this module's
//     form. Except: a provisional run file has none of pid, start_sec and
//     start_usec (all three absent; some but not all is malformed). It is
//     written before the spawn, so a run whose foobar2000 is gone before
//     the pid is known (a crash, a quit, a failed rewrite) is never an
//     orphan output; once the child exists the full run file replaces it.
//  Nothing else in the directory is ever touched: the runner's
//  intake-<pid>-... files, names of other forms, and anything that is not a
//  regular file (directories, symlinks) are left alone.
//
//  Liveness (PLAN.md 3.7 step 6): a run is live when its pid exists AND its
//  start time (proc_pidinfo, sec + usec) equals the run file's. Image names
//  are never used: the CLI may be bun, a wrapper script or a compiled
//  binary. A reused pid has another start time; a zombie, a missing pid or
//  one this user may not inspect is not live.
//
//  Leftovers at init (scanLeftoverRuns, once per session, before this
//  process starts any run in the directory), per stem:
//   - a run file that parses, live: Adopt (Integration holds the lane,
//     marks the roots running and watches the pid with ProcessExitWatch);
//   - a run file that parses, dead: Finish (its output is read here; the
//     caller applies it, then deleteRunFiles);
//   - a provisional run file: its liveness is whether a process of this
//     user still has the output open (OutputWriterLookup; production:
//     findOutputWriter, proc_listpidspath). One does: Adopt, with that
//     process's pid and start time in the file (the CLI writes it as its
//     stdout and leads its own process group, so such a process is
//     preferred).
//     None: Finish when the output exists; with no output the CLI never
//     started (the runner creates the output before the spawn): Sweep;
//   - a run file that does not parse, or names another output: Sweep (the
//     run file, its output and its temp file are deleted);
//   - an output or temp file with no run file: Sweep.
//  A stale <stem>.tmp next to a good run file is deleted too.
//
//  A detached run's output has no exit code when the run was not our child
//  (adopted, or finished by a later session): parseDetachedOutput infers it
//  from the envelope (ok true: 0; ok false with data null or an empty array:
//  2, as parseEnvelope accepts both for exit 2; else 1) and
//  then applies the usual envelope rules (IntakeEnvelope), so a truncated
//  or empty output is E_NO_CLI.
//
//  Result (summarizeRun): summarizeMutation, except that a resume row with
//  resumed "reverted_to_approved" (commands-p3.ts resumeRoot) is a per-root
//  failure, not a success: the root ended `approved` (doc 04 v1.2).
//
//  Tracker states (ExecuteTracker, main thread):
//    Starting  own run: lane taken, spawn requested, no pid yet
//    Running   own run: the child is running (the runner reaps it)
//    Adopted   a run of an earlier session, still running
//    Exited    its process has ended; the result is being read
//  begin -> Starting -> spawned -> Running -> exited -> Exited -> remove;
//  adopt -> Adopted -> exited -> Exited -> remove; remove from any state.
//  Every tracked run's roots count as roots in a live run (Resume stays
//  disabled on them).
//
//  Thread-safety: the tracker is not thread-safe (main thread only). The
//  file functions and parsers are reentrant. ProcessExitWatch may be used
//  from any thread.
//

#pragma once

#include <dispatch/dispatch.h>
#include <sys/types.h>

#include <chrono>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "IntakeCommandArgs.h"
#include "IntakeEnvelope.h"
#include "IntakeMutationResult.h"
#include "IntakeProcess.h"

namespace intake {

// --- names ---

inline constexpr const char *kRunFilePrefix = "execute-";

enum class RunFileKind {
    Run,     // <stem>.run
    Output,  // <stem>.json
    Temp,    // <stem>.tmp (a run file being written)
};

// True when `name` is one of this module's files; sets `stem` and `kind`.
bool parseRunFileName(std::string_view name, std::string &stem, RunFileKind &kind);
bool isRunStem(std::string_view stem);
std::string runFileName(const std::string &stem);     // <stem>.run
std::string runOutputName(const std::string &stem);   // <stem>.json
std::string runTempName(const std::string &stem);     // <stem>.tmp

// "execute-YYYYMMDD-HHMMSS-mmm" for `now`, in local time.
std::string newRunStem(std::chrono::system_clock::time_point now);
// newRunStem(now), with "-2", "-3"... appended while a file of that stem
// exists in `dir` (at most 99 tries; the last one is returned anyway: the
// runner's O_EXCL then refuses it).
std::string uniqueRunStem(const std::string &dir, std::chrono::system_clock::time_point now);

// --- the run file ---

// The follow-ups chosen in the Execute sheet (IntakeExecuteFollowUp): kept
// in the run file from its start, applied when the run ends, whoever
// finishes it (this session, or a later one that adopts or finishes it).
struct RunFollowUps {
    bool recorded = false;     // the run file holds the choice; false: no follow-ups
    bool swap = false;         // swap the playlist rows of the roots now placed
    bool deleteLocal = false;  // then gc those whose census is clear (only with swap)
};

struct RunFile {
    CliCommand command = CliCommand::Execute;  // Execute or Resume
    // Written before the spawn: no pid or start time (both left 0).
    bool provisional = false;
    pid_t pid = 0;
    ProcessStartTime start;
    std::vector<std::string> ids;
    std::vector<std::string> rootPaths;  // empty, or aligned with ids
    std::string output;                  // the stdout file's name, in the same directory
    RunFollowUps followUps;              // swap_after, delete_after
};

// One JSON object (see the top of this file), with a trailing newline.
std::string formatRunFile(const RunFile &file);
// False, with `error`, when `text` is not a valid run file.
bool parseRunFile(std::string_view text, RunFile &out, std::string &error);
// Atomically writes <dir>/<stem>.run (through <stem>.tmp, fsync, rename),
// replacing one that is there; creates `dir` (0700) when it is missing.
// False, with `error`, when it could not.
bool writeRunFile(const std::string &dir, const std::string &stem, const RunFile &file, std::string &error);

// --- liveness ---

using LivenessCheck = std::function<bool(pid_t pid, const ProcessStartTime &start)>;
// readProcessStartTime(pid) succeeds and equals `start`.
bool processIsLive(pid_t pid, const ProcessStartTime &start);

// A live process that has `path` open (a provisional run's output): its pid
// and start time. False when there is none.
using OutputWriterLookup = std::function<bool(const std::string &path, pid_t &pid, ProcessStartTime &start)>;
// proc_listpidspath over this user's processes (not this one) whose start
// time can be read; ranked: stdout is the file, then a process group
// leader, then the lowest pid.
bool findOutputWriter(const std::string &path, pid_t &pid, ProcessStartTime &start);

// --- leftovers ---

struct LeftoverRun {
    std::string stem;
    RunFile file;  // a provisional one adopted: pid and start of the output's writer
    bool byOutput = false;  // adopted through its output's writer (a provisional run file)
    // Finish only: the output's text, or why it could not be read.
    std::string output;
    std::string outputError;
};

struct LeftoverScan {
    std::vector<LeftoverRun> adopt;   // live
    std::vector<LeftoverRun> finish;  // dead; files still in place
    std::vector<std::string> swept;   // names deleted
    std::vector<std::string> notes;   // one per deleted name: "<name>: <why>"
    std::string error;                // the directory could not be listed (a missing one is not an error)
};

// See the top of this file. Stems are visited in name order.
LeftoverScan scanLeftoverRuns(const std::string &dir, const LivenessCheck &live,
                              const OutputWriterLookup &writer = findOutputWriter);

// Reads <dir>/<name> (a regular file, at most 32 MB). False, with `error`.
bool readRunOutput(const std::string &dir, const std::string &name, std::string &text, std::string &error);

// Deletes <stem>.run, <stem>.json and <stem>.tmp in `dir` (regular files
// only). Returns how many were deleted.
size_t deleteRunFiles(const std::string &dir, const std::string &stem);

// --- results ---

// The envelope of a run whose exit code is unknown (see the top of this
// file). `readError` non-empty: the output could not be read (E_NO_CLI).
EnvelopeResult parseDetachedOutput(std::string_view text, const std::string &readError = std::string());

struct RunSummary {
    MutationOutcome outcome;
    std::vector<std::string> reverted;  // resume: ids that ended approved again (failures)
};

RunSummary summarizeRun(CliCommand command, const std::vector<MutationRoot> &roots, const EnvelopeResult &envelope);

// The tooltip and console text of a reverted root (after "resume: ").
extern const char *const kResumeRevertedText;

// --- the tracker ---

enum class RunState {
    Starting,
    Running,
    Adopted,
    Exited,
};

struct TrackedRun {
    std::string stem;
    CliCommand command = CliCommand::Execute;
    RunState state = RunState::Starting;
    pid_t pid = 0;
    ProcessStartTime start;
    std::vector<std::string> ids;
    std::vector<std::string> rootPaths;
    RunFollowUps followUps;  // as the run file holds them
};

class ExecuteTracker {
public:
    // A new own run (Starting). False when `stem` is already tracked or
    // `ids` is empty.
    bool begin(const std::string &stem, CliCommand command, std::vector<std::string> ids,
               std::vector<std::string> rootPaths = {}, RunFollowUps followUps = {});
    // Starting -> Running.
    bool spawned(const std::string &stem, pid_t pid, const ProcessStartTime &start);
    // A leftover live run (Adopted), with the run file's follow-ups. False
    // when `stem` is already tracked.
    bool adopt(const std::string &stem, const RunFile &file);
    // Running or Adopted -> Exited.
    bool exited(const std::string &stem);
    // Forgets the run, whatever its state.
    bool remove(const std::string &stem);

    const TrackedRun *find(const std::string &stem) const;
    const std::vector<TrackedRun> &runs() const { return runs_; }
    bool empty() const { return runs_.empty(); }
    // The roots of every tracked run, each once, in run order.
    std::vector<std::string> liveRunIds() const;

private:
    TrackedRun *findMutable(const std::string &stem);
    std::vector<TrackedRun> runs_;
};

// --- watching a process that is not (necessarily) our child ---

// Calls `onExit` once on `queue` when the process `pid` with start time
// `start` ends: a DISPATCH_SOURCE_TYPE_PROC NOTE_EXIT source, which works
// for any pid, plus one liveness check right after it is armed (a process
// that ended, or whose pid was reused, before that is reported at once).
// Then waitpid(pid) (WNOHANG unless the source saw the exit): it reaps the
// pid only when it is this process's child (tests); for an adopted run it
// fails with ECHILD, which is fine. Never signals anything. Destroying the watch, or cancel(),
// guarantees `onExit` does not run afterwards (unless it is running).
class ProcessExitWatch {
public:
    ProcessExitWatch(pid_t pid, const ProcessStartTime &start, dispatch_queue_t queue, std::function<void()> onExit,
                     LivenessCheck live = processIsLive);
    ~ProcessExitWatch();
    ProcessExitWatch(const ProcessExitWatch &) = delete;
    ProcessExitWatch &operator=(const ProcessExitWatch &) = delete;

    void cancel();
    pid_t pid() const { return pid_; }

    struct State;

private:
    pid_t pid_;
    std::shared_ptr<State> state_;
};

} // namespace intake
