//
//  IntakeCliRunner.h
//  foo_jl_intake
//
//  One intake CLI call end to end: IntakeCommandArgs builds it,
//  IntakeProcess runs it under the policy of its command class, and
//  IntakeEnvelope interprets what it left behind (PLAN.md B1, 3.4).
//
//   Class          Output                   Budget
//   ReadOnly       pipes                    KillAtBudget (E_CLI_TIMEOUT, killed)
//   Mutating       files in outputDirectory ReportAtBudget (E_CLI_TIMEOUT
//                                           reported through onBudget, the
//                                           real result follows; killed only
//                                           at the hard cap). Dry runs too:
//                                           doc 03 v1.2 classifies a command
//                                           whatever its flags.
//   ExecuteDryRun  files in outputDirectory ReportOnly (no E_CLI_TIMEOUT:
//                                           doc 03 excepts `execute`, dry run
//                                           included; the budget is only the
//                                           mutation lane's release, the real
//                                           result follows; never killed)
//   Detached       files in outputDirectory Unbounded (no report, never
//                                           killed)
//
//  ProcessRunner::cancelReadLane() and closeReadLane() (on_quit) kill
//  ReadOnly calls only and leave every other class running.
//
//  A refused request (IntakeCommandArgs: a mutating command with no ids, an
//  invalid id, ...) returns false synchronously: nothing is spawned and no
//  handler runs. Everything else returns true and the completion runs
//  exactly once on `queue`, including the host-synthesized E_NO_CLI for a
//  configuration that cannot run (no CLI path, bun missing).
//
//  Thread-safety: may be called from any thread; see IntakeProcess.h.
//

#pragma once

#import <Foundation/Foundation.h>

#include <functional>
#include <string>

#include "IntakeCommandArgs.h"
#include "IntakeEnvelope.h"
#include "IntakeProcess.h"

namespace intake {

struct CliRunOptions {
    ProcessLimits limits;        // budgets and caps; the defaults are production's
    std::string outputDirectory; // required for every class but ReadOnly
    bool keepOutputFiles = false;
};

struct CliResult {
    CliCommand command = CliCommand::Version;
    CommandClass commandClass = CommandClass::ReadOnly;
    EnvelopeResult envelope;
    ProcessResult process;       // diagnostics: stderr, elapsed, pid, flags
};

// What the elapsed budget means for the call (doc 03 v1.2 "Timeouts", doc 04
// "Timeouts" table: classified by command, whatever its flags).
enum class CliBudgetEvent {
    // ReadOnly (being killed; its completion follows with outcome Timeout)
    // or Mutating, dry runs included (it keeps running): report
    // E_CLI_TIMEOUT.
    Timeout,
    // ExecuteDryRun: `execute` is excepted from the report, so no
    // E_CLI_TIMEOUT. The call keeps running and is never killed; the
    // mutation lane may let go of it (doc 04 "Mutation lane").
    LaneRelease,
};

// The event for a class: Timeout, except LaneRelease for ExecuteDryRun.
// Detached calls have no budget and never get one.
CliBudgetEvent budgetEventFor(CommandClass commandClass);

// Runs on `queue` once, when the budget elapses (never for Detached).
using CliBudgetHandler = std::function<void(CliBudgetEvent event)>;
using CliCompletion = std::function<void(CliResult &&result)>;

// ~/Library/Caches/foo_jl_intake (the user Caches directory plus
// foo_jl_intake): the production output directory for every class but
// ReadOnly. Only computed; IntakeProcess creates it on first use. Empty when
// Foundation reports no Caches directory.
std::string defaultCliOutputDirectory();

// False, with `refusal` (optional) set, when the request is refused.
bool startCliCommand(ProcessRunner &runner, const CliConfig &config, const CliRequest &request,
                     const CliRunOptions &options, dispatch_queue_t _Nullable queue,
                     CliBudgetHandler onBudget, CliCompletion completion,
                     std::string *_Nullable refusal);

} // namespace intake
