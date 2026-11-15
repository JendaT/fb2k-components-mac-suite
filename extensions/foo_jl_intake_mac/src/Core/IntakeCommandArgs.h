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
//  refused, and nothing is spawned. With no roots the CLI acts on everything:
//  `gc` collects every placed root in every income folder
//  (commands-p3.ts:491-493), `execute --approved` places every approved root.
//  For the same reason this module never emits --all-resolved, --approved,
//  --all or a bare `gc`, and it only accepts sidecar ids
//  (^itk_[0-9a-f]{8}$, commands-p2.ts:30): a directory would select every
//  virtual root in it (commands-p2.ts:62-73), and a value starting with "-"
//  would be parsed as a flag. Duplicate ids are passed once (the CLI answers
//  a repeat from the state the first occurrence left behind).
//
//  Executable:
//   - The configured CLI path must be absolute. A path ending in ".ts" runs
//     as [bun, cli.ts, ...], because `#!/usr/bin/env bun` fails from the GUI
//     (cli.ts:1). Anything else is executed directly.
//   - bun is the configured bun path when one is set, otherwise the first
//     executable `bun` in the search directories (default ~/.bun/bin,
//     /opt/homebrew/bin, /usr/local/bin). It is probed for every call, so a
//     non-.ts CLI with a bun shebang finds it on PATH too.
//
//  Environment: the base environment (the process's own unless one is
//  given), with
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
//  (access/stat on the bun candidates and a .ts CLI path) and, without a
//  given base environment, `environ`; never call it on the decorate path.
//

#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace intake {

enum class CliCommand {
    Version,
    Status,
    Collections,
    Propose,
    Assign,
    Approve,
    Reject,
    Execute,
    Resume, // intake execute <ids...> --resume
    Gc,
};

// The CLI command word ("execute" for Resume too).
const char *cliCommandWord(CliCommand command);
// A distinct name for logs ("resume" for Resume).
const char *cliCommandName(CliCommand command);
// Propose, Assign, Approve, Reject, Execute, Resume and Gc.
bool isMutatingCommand(CliCommand command);

struct CliRequest {
    CliCommand command = CliCommand::Version;
    std::vector<std::string> ids;   // sidecar ids; required for mutating commands
    bool dryRun = false;            // mutating commands only
    std::string collection;         // Assign: required; sent as --collection <name> --by user
    std::string reason;             // Reject: optional --reason <text>
    std::vector<std::pair<std::string, std::string>> filters; // Status: --filter key=value
};

struct CliConfig {
    std::string cliPath;   // the preference; empty means not configured (E_NO_CLI)
    std::string bunPath;   // explicit bun; empty means probe the search directories
    std::vector<std::string> bunSearchDirs; // empty means defaultBunSearchDirs()
    std::string rulesDir;  // empty means INTAKE_RULES_DIR is left as inherited
    // The environment to start from, "NAME=value" each. nullopt means a copy
    // of this process's environment.
    std::optional<std::vector<std::string>> baseEnvironment;
};

// How a call runs (PLAN.md 3.2, 3.4).
enum class CommandClass {
    ReadOnly, // version, status, collections: pipes, killed at the budget
    Mutating, // the rest, dry runs included: output files, reported at the budget
    Detached, // execute and resume (not dry runs): output files, never killed
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

// ~/.bun/bin (from HOME in `environment`, skipped when HOME is unset or not
// absolute), /opt/homebrew/bin, /usr/local/bin.
std::vector<std::string> defaultBunSearchDirs(const std::vector<std::string> &environment);

// Request checks first (Refused), then the configuration (NoCli).
CliInvocation buildInvocation(const CliConfig &config, const CliRequest &request);

// True for ^itk_[0-9a-f]{8}$.
bool isSidecarId(std::string_view text);

} // namespace intake
