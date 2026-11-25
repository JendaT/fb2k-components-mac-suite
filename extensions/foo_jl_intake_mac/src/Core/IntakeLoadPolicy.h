//
//  IntakeLoadPolicy.h
//  foo_jl_intake
//
//  The decisions of the loader (IntakeLoader), as pure functions so they are
//  unit-tested without a CLI or the SDK (PLAN.md B3, 3.4, 3.5):
//
//   - loadFailureEffect: what a failed `version` or `status` does, per doc 03
//     v1.2 "Inert state". Inert only when the version gate fails
//     (gateFailureEffect), or when no `status` load has succeeded yet and
//     the call failed with E_NO_CLI, E_NO_RULES or E_CLI_TIMEOUT
//     (IntakeErrorMap's ProviderInert scope). Every other failure keeps the
//     last loaded data (nothing, before the first load) and is logged.
//   - rendersAlike: the invalidation diff. Two snapshots render alike when
//     they hold the same roots (by id) with the same match key, the same
//     membership, the same visual and the same group badge (B6). Anything
//     else is one invalidate-all.
//   - applyMountAliases: re-derives every record's rootKey from its rootPath
//     through the alias table, at load and when the mount table changes.
//   - dropIncomeFolderRoots: the income-folder root guard (a root that is an
//     income folder itself is left out of the load).
//   - remountChangesRows: the invalidation diff of a mount table change.
//   - carryOverUnreadable: a partial `status` that could not read a sidecar
//     keeps the last record of that root (PLAN.md 3.5, risk 7).
//   - The status line for the log, the status block and the income folder
//     list of the preferences page (B5: statusDisplay, incomeDisplay), the
//     "Test CLI" result (cliTestSummary), and the Debug line naming the
//     rules source.
//
//  Thread-safety: pure functions, no shared state.
//

#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "IntakeAutoScan.h"
#include "IntakeCommandArgs.h"
#include "IntakeEnvelope.h"
#include "IntakeIncome.h"
#include "IntakeMountAliases.h"
#include "IntakeSnapshot.h"
#include "IntakeStatusModel.h"
#include "IntakeVersionGate.h"

namespace intake {

enum class LoadStep { Version, Status };

enum class LoadFailureEffect {
    Inert,    // provider-wide inert state (doc 03 "Inert state")
    KeepLast, // keep the last loaded data and log one line
};

// A `version` or `status` call that did not succeed (any outcome but Ok and
// Partial). `everLoaded`: a `status` load has succeeded before.
LoadFailureEffect loadFailureEffect(LoadStep step, const EnvelopeResult &result, bool everLoaded);

// A failed version gate is always inert.
inline LoadFailureEffect gateFailureEffect() { return LoadFailureEffect::Inert; }

// One line for the log and the status line: the first error rendered by
// IntakeErrorMap, " (+N more)" when there are more, else the result's detail.
std::string loadErrorText(const EnvelopeResult &result);

// See the top of this file. Record order does not matter, nor does where a
// member list came from (MemberSource); a record with no member entry
// counts as whole-directory, as in IntakeSnapshot.
bool rendersAlike(const IntakeSnapshot &a, const IntakeSnapshot &b);

// rootKey = aliases.rewrite(normalize(rootPath)) for every record; a record
// whose rootPath does not normalize gets an empty key (matches nothing).
void applyMountAliases(std::vector<IntakeRecord> &records, const MountAliases &aliases);

// The income-folder root guard. A loose audio file directly in an income
// folder makes `scan` write <income>/.intake.json, so the income folder
// becomes a root and every stray row under it (dead rows of moved files
// included) would decorate as that root and offer its actions. Such a root
// is removed from `records` before the members are read and the snapshot
// is built: no member entries, no decoration, tooltip, badge or menu
// action. A root matches when its rootKey (after applyMountAliases) equals
// an income folder's key built the same way: IntakePath normalisation
// (lexical, NFC), then `aliases` (two mounts of one share meet); exact and
// case-sensitive otherwise. A root in a subfolder is kept. With no income
// folders (income not offered, or its last call failed: the caller passes
// none) nothing is removed. Returns the removed roots with the income
// folder's name (its path when the name is empty), in record order.
struct IgnoredIncomeRoot {
    std::string id;
    std::string incomeName;
};
std::vector<IgnoredIncomeRoot> dropIncomeFolderRoots(std::vector<IntakeRecord> &records,
                                                     const std::vector<IncomeFolder> &income,
                                                     const MountAliases &aliases);

// The Info line for one ignored root: "root <id> is the income folder
// <name> itself; ignored (loose files at its top level)".
std::string ignoredIncomeRootLine(const IgnoredIncomeRoot &root);

// A mount table change (PLAN.md risk 5): the alias table went from `before`
// to `after` and the last load's keys were rebuilt from `oldSnapshot`
// (keyed with `before`) into `newSnapshot` (keyed with `after`). True when
// some row can decorate differently, so invalidate-all is needed. A row's
// key rewrites differently only under a changed mount point, and then lies
// under one of MountAliases::changedBases; a row can match a root only when
// the root key and the row's key are on one path. So this is false when the
// snapshots render alike and no root key of either snapshot is a changed
// base, under one, or above one (ignoring ASCII case, conservatively):
// e.g. a share that holds no root mounting or unmounting.
bool remountChangesRows(const IntakeSnapshot &oldSnapshot, const MountAliases &before,
                        const IntakeSnapshot &newSnapshot, const MountAliases &after);

// A partial `status` (exit 1) leaves out each root whose sidecar it could
// not read, with an E_PARSE error naming the sidecar in `path` (CLI
// commands.ts cmdStatus). Sidecar writes are not atomic, so a load that
// runs while a CLI run writes can catch one half written; dropping the
// root would untint its rows and invalidate everything twice (drop, then
// return). So for each E_PARSE whose path ends in a sidecar name
// (IntakeWatchFilter's rule), every record of `previous` it names that
// `records` lacks (by id) is appended to `records` (a relative path names
// nothing):
//   - ".intake.<id>.json": the previous record with that id (ASCII case
//     ignored);
//   - ".intake.json": the previous records whose root path is the
//     sidecar's folder (compared as IntakePath keys).
// Other errors and paths are left alone.
struct UnreadableSidecars {
    std::vector<std::string> directories;  // each named sidecar's folder, as the CLI spelled it, each once
    std::vector<std::string> carriedIds;   // the records appended
};
UnreadableSidecars carryOverUnreadable(std::vector<IntakeRecord> &records, const std::vector<CliError> &errors,
                                       const std::vector<IntakeRecord> &previous);

enum class LoaderState {
    NotConfigured, // no CLI path: nothing runs, nothing renders (not an error)
    Loading,       // the first load is running
    Ready,         // the last load succeeded
    Inert,         // doc 03 inert state
    Stale,         // a refresh failed; the last loaded data is kept
    Failed,        // the first load failed with an error that is not inert-scoped
    Stopped,       // on_quit
};

const char *_Nonnull loaderStateName(LoaderState state);

struct LoaderStatus {
    LoaderState state = LoaderState::Loading;
    std::string cliVersion;   // from the last successful version call
    size_t roots = 0;         // in the snapshot in use
    std::string error;        // Inert, Stale, Failed: why; Ready: a partial load's errors
    size_t partialErrors = 0; // Ready: errors reported by a partial (exit 1) status
    // B5, for the preferences page's income folder list (incomeDisplay):
    bool incomeOffered = false;             // the last passing `version` listed `income`
    std::vector<IncomeFolder> incomeFolders; // the last good `income` call (CLI order)
    std::string incomeError;                // why the last `income` call failed; "" after a good one
    std::vector<std::string> rootFolders;   // parents of the roots in use, lexically clean, sorted, each once
    // B6: `cli` and `commands` of the last `version` call that passed the
    // gate (feature detection for the context menu: cliSupportsCommand);
    // empty until one has, and after reconfigure().
    CliVersionInfo cliInfo;
    // B12: incomeFolders with the spelling FSEvents reports for each
    // (autoScanIncomes over the last watch set built), computed on the loader
    // queue with every watch set update; empty without a CLI path or an
    // onWatchSet handler.
    std::vector<AutoScanIncome> autoScanIncomes;
};

// "Ready · CLI 0.3.0 · 16 roots", "Inactive: ...", ... (UTF-8, a middle dot
// between parts).
std::string statusLine(const LoaderStatus &status);

// The preferences page's status block (B5). Every field is UTF-8 text ready
// to show; an unknown value is an em dash.
enum class StatusTone { Neutral, Good, Warning, Error };
struct StatusDisplay {
    std::string state;      // "Not configured", "Loading…", "Active",
                            // "Active, last refresh failed",
                            // "Inactive: <reason>", "Stopped"
    std::string cliVersion; // "0.3.0"
    std::string roots;      // "16"
    std::string lastError;  // "none", or the error the status carries
    StatusTone tone = StatusTone::Neutral;
};
StatusDisplay statusDisplay(const LoaderStatus &status);

// The income folders the page lists (B5, doc 04 "Preferences page"): the
// folders from `intake income` when the CLI lists that command, otherwise
// the parent folders of the loaded roots. `exists` comes from the CLI for
// income folders; a root's parent held a root at the last load, so it is
// shown as existing (the page never stats folders that may lie on a share).
// A failed `income` call (incomeError) is named in the note, with the last
// good list if there is one, never shown as an empty answer.
struct IncomeDisplayRow {
    std::string name;  // from `income`; empty for a root's parent
    std::string path;
    bool exists = true;
};
struct IncomeDisplay {
    bool fromCli = false;
    std::vector<IncomeDisplayRow> rows;
    std::string note;  // where the list comes from, or why it is empty
};
IncomeDisplay incomeDisplay(const LoaderStatus &status);

// The "Test CLI" result: one `version --json` call (its envelope) and, when
// it answered (Ok or Partial), the version gate over its data. `ok` only
// when the gate passed.
struct CliTestSummary {
    bool ok = false;
    std::string text;  // "CLI 0.3.0, schema 1, 11 commands", "Unsupported CLI: ...", "Failed: ..."
};
CliTestSummary cliTestSummary(const EnvelopeResult &result, const VersionGateResult &gate);

// Which rules folder the CLI will use, for a Debug line (PLAN.md 3.10): the
// configured folder, an inherited INTAKE_RULES_DIR, or the CLI's own
// config.toml.
std::string rulesSourceDescription(const CliConfig &config);

} // namespace intake
