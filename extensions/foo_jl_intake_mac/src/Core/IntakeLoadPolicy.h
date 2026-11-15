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
//     membership and the same visual. Anything else is one invalidate-all.
//   - applyMountAliases: re-derives every record's rootKey from its rootPath
//     through the alias table, at load and when the mount table changes.
//   - The status line for the preferences page (B5) and the log, and the
//     Debug line naming the rules source.
//
//  Thread-safety: pure functions, no shared state.
//

#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "IntakeCommandArgs.h"
#include "IntakeEnvelope.h"
#include "IntakeMountAliases.h"
#include "IntakeSnapshot.h"
#include "IntakeStatusModel.h"

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
};

// "Ready · CLI 0.3.0 · 16 roots", "Inactive: ...", ... (UTF-8, a middle dot
// between parts).
std::string statusLine(const LoaderStatus &status);

// Which rules folder the CLI will use, for a Debug line (PLAN.md 3.10): the
// configured folder, an inherited INTAKE_RULES_DIR, or the CLI's own
// config.toml.
std::string rulesSourceDescription(const CliConfig &config);

} // namespace intake
