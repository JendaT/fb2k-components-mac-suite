//
//  IntakeEnvelope.h
//  foo_jl_intake
//
//  Turns what a CLI call left behind (stdout, exit code, how it ended) into
//  one outcome, per doc 03 "JSON conventions" / "Error surfaces" (contract
//  v1.1) and PLAN.md 3.4 "Envelope":
//
//   1. The stdout, trimmed of ASCII whitespace, must be exactly one JSON
//      object with a boolean `ok`, an array `errors` and a `data` key.
//   2. Exit 0 with ok true and no errors: Ok.
//   3. Exit 1 with ok false and errors: Partial; `data` is the successful
//      subset (null is tolerated as "nothing succeeded").
//   4. Exit 2 with ok false and errors: Failed; `data` is null (shared
//      finish(), commands.ts:68-71), and [] is still tolerated for older
//      CLIs. E_INTERNAL (an uncaught throw since CLI 0.2.1) is an ordinary
//      Failed result.
//   5. Everything else is the host-synthesized E_NO_CLI: empty, garbage or
//      bare-array stdout, a second JSON value, an ok/exit/errors mismatch,
//      any other exit code (126 and 127 included), death by a signal the
//      runner did not send, a spawn errno, truncated stdout, unreadable
//      output files.
//   6. Error entries keep code, msg and path. A code must be a non-empty
//      string; a missing or non-string msg reads as "", path as none.
//   7. Success per root means its id appears in `data` (idsInData). Empty
//      `data` with exit 0 means nothing was done (gc).
//  Runner verdicts come first: a call the runner killed for its budget or
//  hard cap (or abandoned) is E_CLI_TIMEOUT, and one it cancelled is
//  Cancelled. A mutating call that ran past its budget but exited on its own
//  is parsed normally: its real result is the answer.
//
//  Unknown fields are ignored (doc 03, "Versioning").
//
//  Thread-safety: reentrant. Parsing builds Foundation objects; callers on a
//  GCD queue get an autorelease pool from GCD, and the parse functions add
//  their own.
//

#pragma once

#import <Foundation/Foundation.h>

#include <string>
#include <string_view>
#include <vector>

#include "IntakeProcess.h"

namespace intake {

// Host-synthesized codes (doc 03): the CLI never emits these.
extern const char *_Nonnull const kErrorNoCli;      // "E_NO_CLI"
extern const char *_Nonnull const kErrorCliTimeout; // "E_CLI_TIMEOUT"

enum class CliOutcome {
    Ok,        // exit 0
    Partial,   // exit 1: data is the successful subset, errors say what failed
    Failed,    // exit 2: CLI-emitted errors, data nil
    NoCli,     // host E_NO_CLI
    Timeout,   // host E_CLI_TIMEOUT
    Cancelled, // the read lane was cancelled (quit); no error to show
};

const char *_Nonnull cliOutcomeName(CliOutcome outcome);

struct CliError {
    std::string code;
    std::string msg;
    std::string path;
    bool hasPath = false;
};

struct EnvelopeResult {
    CliOutcome outcome = CliOutcome::NoCli;
    // The `data` member: NSArray, NSDictionary, ... ; nil for JSON null and
    // for every outcome other than Ok and Partial.
    id _Nullable data = nil;
    // CLI errors (Partial, Failed), or one host-synthesized entry (NoCli,
    // Timeout). Empty for Ok and Cancelled.
    std::vector<CliError> errors;
    // Why the outcome is NoCli / Timeout / Cancelled, for the log.
    std::string detail;
};

// Rules 1 to 7 for a process that exited with `exitCode`.
EnvelopeResult parseEnvelope(std::string_view stdoutText, int exitCode);

// The runner's verdict first (timeout, cancel, spawn failure, signal,
// truncation, unreadable output), then parseEnvelope.
EnvelopeResult interpretProcessResult(const ProcessResult &result);

// A host-synthesized NoCli / Timeout result with `detail` as its msg.
EnvelopeResult hostNoCli(std::string detail);
EnvelopeResult hostTimeout(std::string detail);

// Rule 7: the `id` strings of the objects in a `data` array, in order.
// Anything else (nil, an object, rows without a string id) contributes
// nothing.
std::vector<std::string> idsInData(id _Nullable data);

} // namespace intake
