//
//  IntakeCommandArgs.h
//  foo_jl_intake
//
//  Builds the argv and environment for one intake CLI call (PLAN.md 3.4).
//  No shell is ever involved: the result is an argv array for posix_spawn,
//  and every value (a collection name such as "[A & B]", a reject reason)
//  reaches the CLI byte for byte. Every call gets --json.
//
//  HARD INVARIANT (PLAN.md risk 3a): a mutating command (propose, assign,
//  approve, reject, execute, resume, gc; dry runs included) with no ids is
//  refused, and nothing is spawned. With no roots the CLI can act on
//  everything: up to CLI 0.2.1 a bare `gc` collects every placed root in
//  every income folder (commands-p3.ts:491-493; from 0.3.0, contract v1.2,
//  it is E_BAD_ARGS without --all), and `execute --approved` places every
//  approved root.
//  scan (B12) takes no ids: it names exactly one income folder
//  (CliRequest::income), and one without is refused (the only other form
//  is `scan --all`). The argument is the income's name, or its absolute
//  path from `income --json` when the name starts with "-": the CLI's
//  parseArgs would take "--all" or "--json" as a flag (cli.ts:89-92), and
//  it matches an income by name or by that path (commands.ts:181). No dry
//  run is built for scan.
//  For the same reason this module never emits --all-resolved, --approved,
//  --all or a bare `gc` or `scan`, and it only accepts sidecar ids
//  (^itk_[0-9a-f]{8}$, commands-p2.ts:30): a directory would select every
//  virtual root in it (commands-p2.ts:62-73), and a value starting with "-"
//  would be parsed as a flag. Duplicate ids are passed once (the CLI answers
//  a repeat from the state the first occurrence left behind).
//  Ids bound `execute <ids> --resume` only from CLI 0.2.1 (5a665e93); older
//  CLIs ignore them and resume every placing root. So Resume is refused
//  unless CliConfig::cliVersion is 0.2.1 or later (cliSupportsPerRootResume)
//  or the CLI lists `commands` (CliConfig::cliListsCommands, contract v1.2).
//
//  Executable:
//   - The configured CLI path must be absolute. A path ending in ".ts" runs
//     as [bun, cli.ts, ...], because `#!/usr/bin/env bun` fails from the GUI
//     (cli.ts:1). Anything else is executed directly.
//   - bun is the configured bun path when one is set, otherwise the first
//     executable `bun` in the search directories (default ~/.bun/bin,
//     /opt/homebrew/bin, /usr/local/bin; IntakeSettingsParse findBun, which
//     the preferences page shows too). It is probed for every call, so a
//     non-.ts CLI with a bun shebang finds it on PATH too. A configured bun
//     path that is not an executable file is an error (NoCli) only for a .ts
//     CLI; any other CLI does not need bun, so it is ignored and bun probed.
//
//  Environment: the base environment (CliConfig::baseEnvironment, a
//  snapshot taken on the main thread), with
//   - PATH = the bun directory (when bun was found), then
//     /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin, then
//     the remaining entries of the inherited PATH; duplicates dropped. Child
//     tools (metaflac, python3 for the beets shim; providers.ts:168,
//     provenance.ts:22) then resolve the same way whether foobar2000 was
//     started from Finder or from a terminal.
//   - INTAKE_RULES_DIR = the configured rules folder, only when one is
//     configured (config.ts:15-16). Otherwise an inherited value is kept.
//
//  Results:
//   - Refused: the request breaks an invariant (a caller bug). Nothing may
//     be spawned; IntakeCliRunner returns the refusal synchronously.
//   - NoCli: the configuration cannot run (no CLI path, bun missing, ...).
//     IntakeCliRunner reports it as host-synthesized E_NO_CLI (doc 03).
//
//  Thread-safety: buildInvocation is reentrant. It reads the filesystem
//  (access/stat on the bun candidates and a .ts CLI path), so never call it
//  on the decorate path. It never reads `environ`: a concurrent setenv can
//  reallocate that array under a reader on another thread.
//

#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "IntakeSettingsParse.h"  // defaultBunSearchDirs, findBun, isExecutableFile

namespace intake {

enum class CliCommand {
    Version,
    Status,
    Collections,
    Income,  // contract v1.2 (CLI 0.3.0); feature-detect with cliSupportsCommand
    Propose,
    Assign,
    Approve,
    Reject,
    Execute,
    Resume, // intake execute <ids...> --resume
    Gc,
    Scan,   // intake scan <income> (B12); feature-detect with cliSupportsCommand
};

// The CLI command word ("execute" for Resume too).
const char *cliCommandWord(CliCommand command);
// A distinct name for logs ("resume" for Resume).
const char *cliCommandName(CliCommand command);
// Propose, Assign, Approve, Reject, Execute, Resume, Gc and Scan. Version,
// Status, Collections and Income are read-only.
bool isMutatingCommand(CliCommand command);

struct CliRequest {
    CliCommand command = CliCommand::Version;
    std::vector<std::string> ids;   // sidecar ids; required for mutating commands but Scan
    bool dryRun = false;            // mutating commands only (not Scan)
    std::string collection;         // Assign: required; sent as --collection <name> --by user
    std::string reason;             // Reject: optional --reason <text>
    std::vector<std::pair<std::string, std::string>> filters; // Status: --filter key=value
    std::string income;             // Scan: required, the income name from `income --json`
    std::string incomePath;         // Scan: that income's absolute path; required (and sent
                                    // instead of the name) when the name starts with "-"
};

struct CliConfig {
    std::string cliPath;   // the preference; empty means not configured (E_NO_CLI)
    std::string bunPath;   // explicit bun; empty means probe the search directories
    std::vector<std::string> bunSearchDirs; // empty means defaultBunSearchDirs()
    std::string rulesDir;  // empty means INTAKE_RULES_DIR is left as inherited
    // The environment to start from, "NAME=value" each: take it with
    // processEnvironmentSnapshot() on the main thread and keep it here.
    // nullopt is a configuration that cannot run (NoCli).
    std::optional<std::vector<std::string>> baseEnvironment;
    // The `cli` version from the last `version` call; empty until known.
    // Resume is refused unless it is 0.2.1 or later (see the invariant),
    // or the same call listed `commands`.
    std::string cliVersion;
    // That `version` call listed `commands` (contract v1.2, CLI 0.3.0 and
    // later), which scope `execute <ids> --resume` to the ids whatever the
    // `cli` string says (a pre-release such as "0.3.0-rc.1" fails the strict
    // semver). Set both from one CliVersionInfo, so Resume is accepted here
    // whenever cliSupportsCommand offers it.
    bool cliListsCommands = false;
};

// How a call runs (PLAN.md 3.2, 3.4; doc 03 v1.2 "Timeouts"). A mutating
// command is classified by command, whatever its flags: a dry run is never
// killed at the 10 s budget.
enum class CommandClass {
    ReadOnly,      // version, status, collections, income: pipes, killed at
                   // the budget
    Mutating,      // propose, assign, approve, reject, gc, scan, dry runs
                   // included: output files, reported at the budget, killed
                   // only at the 15-minute hard cap
    ExecuteDryRun, // execute or resume with --dry-run: output files, no
                   // E_CLI_TIMEOUT (doc 03 excepts execute), a lane release
                   // at the budget, never killed (execute is never killed)
    Detached,      // execute and resume: output files, no budget report,
                   // never killed
};

CommandClass commandClass(const CliRequest &request);

enum class BuildStatus {
    Ok,
    NoCli,   // the configuration cannot run the CLI
    Refused, // the request breaks an invariant; never spawn
};

struct CliInvocation {
    BuildStatus status = BuildStatus::Refused;
    std::string message;                   // NoCli / Refused: why
    std::string executable;                // Ok: absolute path, argv[0]
    std::vector<std::string> arguments;    // Ok: the full argv
    std::vector<std::string> environment;  // Ok: the full environment
    CommandClass commandClass = CommandClass::ReadOnly;
};

// A copy of this process's environment, "NAME=value" each. Reads `environ`,
// so call it on the main thread (at init), never on a worker queue.
std::vector<std::string> processEnvironmentSnapshot();

// Request checks first (Refused, including Resume on a CLI older than
// 0.2.1), then the configuration (NoCli).
CliInvocation buildInvocation(const CliConfig &config, const CliRequest &request);

// True for ^itk_[0-9a-f]{8}$.
bool isSidecarId(std::string_view text);

} // namespace intake
