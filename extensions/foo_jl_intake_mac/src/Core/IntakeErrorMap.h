//
//  IntakeErrorMap.h
//  foo_jl_intake
//
//  Error scope and short user-facing text (PLAN.md 3.4 "Error scope",
//  doc 03 "Error surfaces").
//
//  Scope:
//   - ProviderInert: E_NO_CLI, E_NO_RULES or E_CLI_TIMEOUT on `version` or
//     `status`. Without those two calls there is nothing to decorate, so the
//     whole provider goes inert (tooltip-only rows, a preferences status
//     line, one console line). A failed version gate is also provider-wide;
//     the gate (B2) decides that itself.
//   - PerCommand: everything else, E_INTERNAL included (an uncaught throw
//     inside one CLI call, CLI 0.2.1+), and every error of a mutating or
//     picker call. Shown as a console line plus a `lastError` tooltip on the
//     affected root.
//
//  Text: known codes get a short fixed phrase, followed by the CLI's msg
//  when it has one. The vocabulary is open (doc 03), so an unknown code is
//  rendered from its msg (or the code itself when msg is empty), never
//  treated as a failure of its own. A path, when present, is appended in
//  parentheses.
//
//  Thread-safety: pure functions over constant tables.
//

#pragma once

#include <string>
#include <string_view>
#include <vector>

#include "IntakeCommandArgs.h"
#include "IntakeEnvelope.h"

namespace intake {

enum class ErrorScope {
    PerCommand,
    ProviderInert,
};

// Scope of one error code returned by `command`.
ErrorScope errorScope(CliCommand command, std::string_view code);

// ProviderInert when any error of `result` is provider-wide for `command`.
// Ok and Cancelled results have no errors and are PerCommand.
ErrorScope resultScope(CliCommand command, const EnvelopeResult &result);

// The short phrase for a known code, or nullptr for an unknown one.
const char *knownErrorText(std::string_view code);

// One line for a tooltip or the console (see the top of this file).
std::string renderError(const CliError &error);

} // namespace intake
