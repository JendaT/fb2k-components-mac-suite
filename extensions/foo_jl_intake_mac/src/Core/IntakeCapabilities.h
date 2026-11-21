//
//  IntakeCapabilities.h
//  foo_jl_intake
//
//  Which commands a CLI accepts, from the `data` of `intake version --json`
//  (doc 03 v1.2, "Versioning").
//
//   - Contract v1.2 (CLI 0.3.0 and later): `data.commands` is an array of
//     the command names the CLI accepts, and it is the answer: a command is
//     supported when its word (cliCommandWord) is listed. Resume is
//     `execute`: a v1.2 CLI scopes `execute <ids> --resume` to the named
//     roots (the all-roots form is `execute --resume` without roots).
//   - Without a `commands` array (CLI 0.2.1 and older), the `cli` semver
//     decides (IntakeSemver): Reject from 0.2.0, per-root Resume from 0.2.1,
//     Income never (it is new in 0.3.0), Scan never (B12's automatic scan
//     runs only on a CLI that lists it). Every other command exists since
//     CLI 0.1.0. An unparseable `cli` never satisfies a minimum, so Reject
//     and Resume stay off.
//  A `commands` member that is not an array counts as absent; entries that
//  are not strings are ignored.
//
//  The version gate (`schema == 1`) is a separate check (B2); this module
//  reads only `cli` and `commands`.
//
//  Thread-safety: pure functions, no shared state. parseCliVersionInfo
//  reads Foundation objects and adds its own autorelease pool.
//

#pragma once

#import <Foundation/Foundation.h>

#include <string>
#include <vector>

#include "IntakeCommandArgs.h"

namespace intake {

struct CliVersionInfo {
    std::string cli;                   // `cli`; empty when absent or not a string
    bool hasCommands = false;          // `commands` was an array (contract v1.2)
    std::vector<std::string> commands; // its string entries, in order
};

// Reads `cli` and `commands` from the `data` of a version envelope. Anything
// but a dictionary gives an empty info.
CliVersionInfo parseCliVersionInfo(id _Nullable data);

// Whether the CLI described by `info` accepts `command` (see above).
bool cliSupportsCommand(const CliVersionInfo &info, CliCommand command);

} // namespace intake
